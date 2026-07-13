#!/usr/bin/env bash
# 场景 E5：缓存击穿 — 热点 key 过期瞬间并发读，互斥锁避免 DB 尖峰
set -euo pipefail

DIRECT_URL="${DIRECT_URL:-http://192.168.16.1:8765}"
REDIS_CONTAINER="${REDIS_CONTAINER:-redis-alpine}"
REDIS_DB="${REDIS_DB:-1}"

HOT_DEVICE="${HOT_DEVICE:-e5-hot-device}"
WARMUP_REPORTS="${WARMUP_REPORTS:-5}"
CONCURRENT="${CONCURRENT:-50}"
LOCK_ENABLED_HINT="${LOCK_ENABLED_HINT:-true}"
# 无 docker/redis-cli 时改用等待 TTL：需临时把 app.cache.stats-ttl-seconds 改为 5
WAIT_TTL_FALLBACK="${WAIT_TTL_FALLBACK:-false}"
TTL_WAIT_SEC="${TTL_WAIT_SEC:-8}"

stats_url() {
  echo "$DIRECT_URL/api/v1/devices/$1/stats"
}

fetch_source() {
  curl -sf "$(stats_url "$1")" | grep -o '"source":"[^"]*"' | head -1 | cut -d'"' -f4
}

resolve_redis_container() {
  if [ -n "$REDIS_CONTAINER" ] && docker ps --format '{{.Names}}' | grep -qx "$REDIS_CONTAINER"; then
    return 0
  fi
  REDIS_CONTAINER="$(docker ps --format '{{.Names}}' | grep -i redis | head -1 || true)"
  [ -n "$REDIS_CONTAINER" ]
}

redis_cli() {
  docker exec "$REDIS_CONTAINER" redis-cli -n "$REDIS_DB" "$@"
}

redis_del_key() {
  redis_cli DEL "$1" >/dev/null
}

expire_cache_by_docker() {
  echo "  使用 Docker 容器 $REDIS_CONTAINER 删除缓存 key"
  redis_del_key "device:stats:${HOT_DEVICE}"
  echo "  已 DEL device:stats:${HOT_DEVICE}"
}

expire_cache_by_wait() {
  echo "  无 Redis 容器：等待 TTL 过期（需 application.yml 中 stats-ttl-seconds 已改为较小值，如 5）"
  echo "  等待 ${TTL_WAIT_SEC}s ..."
  sleep "$TTL_WAIT_SEC"
  echo "  等待完成，假定缓存已过期"
}

prepare_breakdown_test() {
  if resolve_redis_container 2>/dev/null; then
    expire_cache_by_docker
    miss_source="$(fetch_source "$HOT_DEVICE")"
    echo "  过期后单次 stats source=$miss_source（预期 db，并回填缓存）"
    echo ""
    redis_del_key "device:stats:${HOT_DEVICE}"
    redis_del_key "device:stats:lock:${HOT_DEVICE}"
    echo "  再次 DEL stats + lock key，准备并发击穿测试"
    return 0
  fi

  if [ "$WAIT_TTL_FALLBACK" = "true" ]; then
    expire_cache_by_wait
    echo "  提示：请确认预热后已至少请求过一次 stats 建立缓存"
    return 0
  fi

  echo "错误：未找到 Redis Docker 容器，且未启用 WAIT_TTL_FALLBACK"
  echo ""
  echo "可选方案（任选其一）："
  echo "  1. 指定容器名：export REDIS_CONTAINER=你的redis容器名"
  echo "  2. 启用等待 TTL：export WAIT_TTL_FALLBACK=true"
  echo "     并临时修改 application.yml：app.cache.stats-ttl-seconds: 5"
  echo "     预热后脚本会 sleep ${TTL_WAIT_SEC}s 再并发"
  echo "  3. docker ps | grep -i redis  确认 Redis 容器在运行"
  exit 1
}

show_cached_value() {
  if resolve_redis_container 2>/dev/null; then
    echo "--- 当前缓存 key（docker exec redis-cli）---"
    redis_cli GET "device:stats:${HOT_DEVICE}" | head -c 200
    echo ""
    echo ""
  else
    echo "--- 跳过 Redis GET（无容器）---"
    echo ""
  fi
}

echo "=== E5 缓存击穿（热点 key + 并发读）==="
echo "API        : $DIRECT_URL"
echo "热点 device: $HOT_DEVICE"
echo "并发数     : $CONCURRENT"
echo "Redis 容器 : ${REDIS_CONTAINER:-（自动检测 docker ps | grep redis）}"
echo "当前配置   : app.cache.breakdown-lock-enabled（建议 $LOCK_ENABLED_HINT）"
echo ""
echo "前置："
echo "  [ ] device-report-service 已启动"
echo "  [ ] Redis Docker 容器运行中，或 WAIT_TTL_FALLBACK=true"
echo "  [ ] breakdown-lock-enabled=true 时 DB 尖峰应较窄；false 时并发更易打 DB"
echo ""

echo "--- 健康检查 ---"
curl -sf "$DIRECT_URL/actuator/health" | head -c 200
echo ""
echo ""

echo "--- Step 1：预热 — 写入 ${WARMUP_REPORTS} 条上报并加载 stats 缓存 ---"
for i in $(seq 1 "$WARMUP_REPORTS"); do
  curl -s -o /dev/null -w "  report [$i/$WARMUP_REPORTS] HTTP %{http_code}\n" -X POST \
    "$DIRECT_URL/api/v1/devices/${HOT_DEVICE}/reports" \
    -H "Content-Type: application/json" \
    -d "{\"payload\":{\"temperature\":25,\"seq\":$i}}"
done

source1="$(fetch_source "$HOT_DEVICE")"
source2="$(fetch_source "$HOT_DEVICE")"
echo "  首次 stats source=$source1"
echo "  再次 stats source=$source2（预期 redis）"
echo ""

echo "--- Step 2：模拟缓存过期 ---"
prepare_breakdown_test
echo ""

echo "--- Step 3：并发 ${CONCURRENT} 请求同一热点 stats ---"
tmpdir="$(mktemp -d)"
start_ms=$(date +%s%3N)
for i in $(seq 1 "$CONCURRENT"); do
  (
    fetch_source "$HOT_DEVICE" > "$tmpdir/worker-$i"
  ) &
done
wait
end_ms=$(date +%s%3N)
elapsed=$((end_ms - start_ms))
echo "并发完成，耗时约 ${elapsed}ms"
echo ""
echo "source 分布："
sort "$tmpdir"/worker-* | uniq -c | sed 's/^/  /'
rm -rf "$tmpdir"
echo ""

show_cached_value

echo "=== E5 预期结果 ==="
echo ""
echo "breakdown-lock-enabled=true（默认）："
echo "  - 并发瞬间：仅少数线程 source=db（理想 db=1）"
echo "  - 其余 source=redis（等待锁释放后命中缓存）"
echo "  - redis 占绝大多数"
echo ""
echo "breakdown-lock-enabled=false（改 yml 重启后再跑）："
echo "  - source=db 次数明显增多"
echo "  - DB 连接尖峰更明显"
echo ""
echo "PromQL："
echo '  rate(cache_access_total{application="device-report-service",result="hit"}[1m])'
echo '  rate(cache_access_total{application="device-report-service",result="miss"}[1m])'
echo '  hikaricp_connections_active{application="device-report-service"}'
echo ""
echo "Redis 验证（有 Docker 时）："
echo "  docker exec \$REDIS_CONTAINER redis-cli -n $REDIS_DB GET device:stats:${HOT_DEVICE}"
