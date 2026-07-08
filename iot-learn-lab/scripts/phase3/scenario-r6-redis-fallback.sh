#!/usr/bin/env bash
# 场景 R6：Redis 降级兜底 — 命中最近一次成功 ACK 缓存
set -euo pipefail

DIRECT_URL="${DIRECT_URL:-http://192.168.16.1:8765}"
REDIS_HOST="${REDIS_HOST:-192.168.19.64}"
DEVICE_ID="${DEVICE_ID:-r6-device-1}"
WARMUP="${WARMUP:-5}"

echo "=== R6 Redis 降级兜底 ==="
echo "deviceId: $DEVICE_ID"
echo ""
echo "前置（Task 13 完成后）："
echo "  [ ] spring-boot-starter-data-redis 已接入"
echo "  [ ] Redis ${REDIS_HOST}:6379 可访问"
echo "  [ ] Fallback 逻辑优先读 dispatch:ack:{deviceId} 缓存"
echo ""

echo "--- 阶段 1：dispatch 正常，预热写入 Redis 缓存 ($WARMUP 次) ---"
for n in $(seq 1 "$WARMUP"); do
  curl -s -w " HTTP %{http_code}\n" -X POST \
    "$DIRECT_URL/api/v1/devices/${DEVICE_ID}/reports-with-dispatch" \
    -H "Content-Type: application/json" \
    -d "{\"payload\":{\"temperature\":25,\"seq\":$n}}"
done

echo ""
echo "--- 阶段 2：停止 command-dispatch-service 后按 Enter ---"
read -r _

echo "--- 阶段 3：再次请求同一 deviceId ---"
response=$(curl -s -w "\nHTTP %{http_code}" -X POST \
  "$DIRECT_URL/api/v1/devices/${DEVICE_ID}/reports-with-dispatch" \
  -H "Content-Type: application/json" \
  -d '{"payload":{"temperature":25}}')
echo "$response"

echo ""
echo "=== R6 完成 ==="
echo "验证："
echo "  1. 响应 JSON 含 source=redis-cache（或等价字段）"
echo "  2. 区别于 R5 的静态 fallback（ackId=fallback-xxx）"
echo "  3. redis-cli -h ${REDIS_HOST} GET dispatch:ack:${DEVICE_ID} 有值"
