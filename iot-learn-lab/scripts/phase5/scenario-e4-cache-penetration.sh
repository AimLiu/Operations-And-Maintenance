#!/usr/bin/env bash
# 场景 E4：缓存穿透 — 查询不存在的 deviceId，空值缓存挡 DB
set -euo pipefail

DIRECT_URL="${DIRECT_URL:-http://192.168.16.1:8765}"
REDIS_CONTAINER="${REDIS_CONTAINER:-}"
REDIS_DB="${REDIS_DB:-1}"

FAKE_DEVICE="${FAKE_DEVICE:-e4-fake-penetration}"
REPEAT_SAME="${REPEAT_SAME:-15}"
UNIQUE_FAKE_COUNT="${UNIQUE_FAKE_COUNT:-20}"
UNIQUE_PREFIX="${UNIQUE_PREFIX:-e4-fake-unique}"

stats_url() {
  echo "$DIRECT_URL/api/v1/devices/$1/stats"
}

fetch_source() {
  curl -sf "$(stats_url "$1")" | grep -o '"source":"[^"]*"' | head -1 | cut -d'"' -f4
}

fetch_body() {
  curl -sf "$(stats_url "$1")"
}

resolve_redis_container() {
  if [ -n "$REDIS_CONTAINER" ] && docker ps --format '{{.Names}}' | grep -qx "$REDIS_CONTAINER"; then
    return 0
  fi
  REDIS_CONTAINER="$(docker ps --format '{{.Names}}' | grep -i redis | head -1 || true)"
  [ -n "$REDIS_CONTAINER" ]
}

redis_del_key() {
  if resolve_redis_container 2>/dev/null; then
    docker exec "$REDIS_CONTAINER" redis-cli -n "$REDIS_DB" DEL "$1" >/dev/null 2>&1 || true
  fi
}

echo "=== E4 缓存穿透（空值缓存）==="
echo "API   : $DIRECT_URL/api/v1/devices/{deviceId}/stats"
echo "Redis : Docker 容器 ${REDIS_CONTAINER:-（自动检测）} db=$REDIS_DB"
echo ""
echo "前置："
echo "  [ ] device-report-service 已启动"
echo "  [ ] app.cache.null-cache-enabled=true（默认）"
echo "  [ ] 建议重启后测试，避免旧 Redis 数据干扰"
echo ""

echo "--- 健康检查 ---"
curl -sf "$DIRECT_URL/actuator/health" | head -c 200
echo ""
echo ""

echo "--- 阶段 1：同一不存在 deviceId 重复请求 ${REPEAT_SAME} 次 ---"
echo "deviceId: $FAKE_DEVICE"
echo ""
redis_del_key "device:stats:${FAKE_DEVICE}"

db_count=0
null_hit_count=0
other_count=0
for i in $(seq 1 "$REPEAT_SAME"); do
  source="$(fetch_source "$FAKE_DEVICE")"
  echo "  [$i/$REPEAT_SAME] source=$source"
  case "$source" in
    db) db_count=$((db_count + 1)) ;;
    redis-null) null_hit_count=$((null_hit_count + 1)) ;;
    *) other_count=$((other_count + 1)) ;;
  esac
done
echo ""
echo "汇总：db=$db_count  redis-null=$null_hit_count  other=$other_count"
echo ""

echo "--- 阶段 2：${UNIQUE_FAKE_COUNT} 个不同不存在 deviceId（各请求 1 次）---"
unique_db=0
unique_null=0
for i in $(seq 1 "$UNIQUE_FAKE_COUNT"); do
  id="${UNIQUE_PREFIX}-${i}"
  source="$(fetch_source "$id")"
  echo "  [$i/$UNIQUE_FAKE_COUNT] deviceId=$id source=$source"
  case "$source" in
    db) unique_db=$((unique_db + 1)) ;;
    redis-null) unique_null=$((unique_null + 1)) ;;
    *) ;;
  esac
done
echo ""
echo "汇总：db=$unique_db  redis-null=$unique_null"
echo ""

echo "--- 阶段 1 最后一次响应示例 ---"
fetch_body "$FAKE_DEVICE"
echo ""
echo ""

echo "=== E4 预期结果（null-cache-enabled=true）==="
echo "  阶段 1："
echo "    - 第 1 次：source=db，reportCount=0"
echo "    - 第 2~N 次：source=redis-null（空值缓存命中，不再查 DB）"
echo "    - db 次数 ≈ 1，redis-null 次数 ≈ $((REPEAT_SAME - 1))"
echo "  阶段 2："
echo "    - 每个新 fake id 首次 source=db"
echo "    - 同一 id 立即再请求应变 redis-null（本阶段各只请求一次，故 db ≈ $UNIQUE_FAKE_COUNT）"
echo ""
echo "对比实验：设 app.cache.null-cache-enabled=false 并重启，"
echo "  阶段 1 中 db 次数会接近 $REPEAT_SAME（每次穿透打 DB）"
echo ""
echo "PromQL："
echo '  rate(cache_access_total{application="device-report-service",result="null_hit"}[1m])'
echo '  rate(cache_access_total{application="device-report-service",result="miss"}[1m])'
echo ""
echo "Redis 验证（有 Docker 时）："
echo "  docker exec \${REDIS_CONTAINER:-<redis容器>} redis-cli -n $REDIS_DB GET device:stats:${FAKE_DEVICE}"
echo "  预期值：__NULL__"
