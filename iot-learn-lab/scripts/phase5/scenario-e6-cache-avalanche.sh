#!/usr/bin/env bash
# 场景 E6：缓存雪崩 — 固定 TTL 同时过期 vs 随机 TTL 分散过期
set -euo pipefail

DIRECT_URL="${DIRECT_URL:-http://192.168.16.1:8765}"
REDIS_CONTAINER="${REDIS_CONTAINER:-redis-alpine}"
REDIS_DB="${REDIS_DB:-1}"

DEVICE_COUNT="${DEVICE_COUNT:-100}"
DEVICE_PREFIX="${DEVICE_PREFIX:-e6-ava}"
FIXED_TTL_SEC="${FIXED_TTL_SEC:-10}"
JITTER_WAIT_SEC="${JITTER_WAIT_SEC:-16}"
# 第二阶段需临时改 yml：stats-ttl-seconds=10, stats-ttl-jitter-seconds=5 并重启
SHORT_TTL_DEMO="${SHORT_TTL_DEMO:-true}"

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

redis_del() {
  redis_cli DEL "$1" >/dev/null 2>&1 || true
}

burst_get_sources() {
  local prefix="$1"
  local count="$2"
  local tmpdir
  tmpdir="$(mktemp -d)"
  local i id

  for i in $(seq 1 "$count"); do
    id="${prefix}-${i}"
    (
      fetch_source "$id" > "$tmpdir/s-$i"
    ) &
  done
  wait

  local db=0 redis=0 redis_null=0 other=0
  local src
  for i in $(seq 1 "$count"); do
    src="$(cat "$tmpdir/s-$i")"
    case "$src" in
      db) db=$((db + 1)) ;;
      redis) redis=$((redis + 1)) ;;
      redis-null) redis_null=$((redis_null + 1)) ;;
      *) other=$((other + 1)) ;;
    esac
  done
  rm -rf "$tmpdir"
  echo "  db=$db  redis=$redis  redis-null=$redis_null  other=$other"
}

cache_json_for_device() {
  local id="$1"
  printf '{"deviceId":"%s","reportCount":1,"lastReportedAt":"2026-07-10T10:00:00Z"}' "$id"
}

echo "=== E6 缓存雪崩（固定 TTL vs 随机 TTL）==="
echo "API          : $DIRECT_URL/api/v1/devices/{id}/stats"
echo "设备数量     : $DEVICE_COUNT"
echo "device 前缀  : $DEVICE_PREFIX"
echo "固定 TTL     : ${FIXED_TTL_SEC}s（阶段 1 用 redis SET EX）"
echo "Redis 容器   : ${REDIS_CONTAINER:-（自动检测 docker ps | grep redis）}"
echo ""
echo "前置："
echo "  [ ] device-report-service 已启动"
echo "  [ ] Redis Docker 容器运行中"
echo "  [ ] 阶段 2 可选：SHORT_TTL_DEMO=true 且 yml 中 stats-ttl-seconds=10, jitter=5"
echo ""

if ! resolve_redis_container; then
  echo "错误：未找到 Redis 容器。请先 docker ps | grep -i redis"
  echo "或：export REDIS_CONTAINER=你的容器名"
  exit 1
fi
echo "使用 Redis 容器: $REDIS_CONTAINER"
echo ""

echo "--- 健康检查 ---"
curl -sf "$DIRECT_URL/actuator/health" | head -c 200
echo ""
echo ""

echo "--- Step 1：预热 ${DEVICE_COUNT} 个 device（写 DB + 首次 stats）---"
for i in $(seq 1 "$DEVICE_COUNT"); do
  id="${DEVICE_PREFIX}-${i}"
  curl -s -o /dev/null -X POST "$(stats_url "$id" | sed 's|/stats|/reports|')" \
    -H "Content-Type: application/json" \
    -d '{"payload":{"temperature":25,"seq":'"$i"'}}'
  fetch_source "$id" >/dev/null
  if [ $((i % 20)) -eq 0 ]; then
    echo "  已预热 $i / $DEVICE_COUNT"
  fi
done
echo "  预热完成"
echo ""

echo "--- Step 2：阶段 A — 固定 TTL 雪崩（同一 EX=${FIXED_TTL_SEC}s）---"
echo "  通过 docker exec 写入 ${DEVICE_COUNT} 个 key，TTL 完全相同"
for i in $(seq 1 "$DEVICE_COUNT"); do
  id="${DEVICE_PREFIX}-${i}"
  json="$(cache_json_for_device "$id")"
  redis_cli SET "device:stats:${id}" "$json" EX "$FIXED_TTL_SEC" >/dev/null
done
echo "  已 SET device:stats:${DEVICE_PREFIX}-1 .. ${DEVICE_PREFIX}-${DEVICE_COUNT} EX ${FIXED_TTL_SEC}"
echo "  等待 ${FIXED_TTL_SEC}s 让 key 同时过期 ..."
sleep "$FIXED_TTL_SEC"
echo ""
echo "  并发读取 ${DEVICE_COUNT} 个 stats（预期大量 source=db）："
burst_get_sources "$DEVICE_PREFIX" "$DEVICE_COUNT"
echo ""

echo "--- Step 3：阶段 B — 随机 TTL 对比（应用 Cache-Aside + jitter）---"
if [ "$SHORT_TTL_DEMO" != "true" ]; then
  echo "  跳过：未设置 SHORT_TTL_DEMO=true"
  echo ""
  echo "  若要对比随机 TTL，请："
  echo "    1. 临时修改 application.yml："
  echo "         app.cache.stats-ttl-seconds: 10"
  echo "         app.cache.stats-ttl-jitter-seconds: 5"
  echo "    2. 重启 device-report-service"
  echo "    3. export SHORT_TTL_DEMO=true && ./scenario-e6-cache-avalanche.sh"
  echo ""
else
  echo "  删除旧 key，通过 API 重建缓存（各 key TTL = 10~15s 随机）"
  for i in $(seq 1 "$DEVICE_COUNT"); do
    redis_del "device:stats:${DEVICE_PREFIX}-${i}"
  done
  for i in $(seq 1 "$DEVICE_COUNT"); do
    fetch_source "${DEVICE_PREFIX}-${i}" >/dev/null
  done
  echo "  等待 ${JITTER_WAIT_SEC}s（仅最短 TTL 过期，其余仍存活）..."
  sleep "$JITTER_WAIT_SEC"
  echo ""
  echo "  并发读取 ${DEVICE_COUNT} 个 stats（预期 db + redis 混合，非全员 db）："
  burst_get_sources "$DEVICE_PREFIX" "$DEVICE_COUNT"
  echo ""
fi

echo "=== E6 预期结果 ==="
echo ""
echo "阶段 A（固定 TTL / 雪崩）："
echo "  - ${DEVICE_COUNT} 个 key 同时过期"
echo "  - 并发 GET 后 db ≈ ${DEVICE_COUNT}，redis ≈ 0"
echo "  - 表现为 DB 查询尖峰（可用 PG 慢查询 / 连接数 / 应用 SQL 日志观察）"
echo ""
echo "阶段 B（随机 TTL / jitter，SHORT_TTL_DEMO=true）："
echo "  - key 在 10~15s 内分散过期"
echo "  - 等待 ${JITTER_WAIT_SEC}s 后并发 GET：db 与 redis 并存"
echo "  - db 数量应明显少于阶段 A（不会 ${DEVICE_COUNT} 同时 miss）"
echo ""
echo "PromQL："
echo '  rate(cache_access_total{application="device-report-service",result="miss"}[1m])'
echo '  rate(cache_access_total{application="device-report-service",result="hit"}[1m])'
echo '  hikaricp_connections_active{application="device-report-service"}'
echo ""
echo "与 E4/E5 区别："
echo "  E4 穿透 = 查不存在的数据；E5 击穿 = 热点 1 个 key；E6 雪崩 = 大量 key 同时失效"
