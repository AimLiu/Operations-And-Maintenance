#!/usr/bin/env bash
# 场景 R1：Feign 链路基准线 — 双服务正常时单次/小批量调用
set -euo pipefail

DIRECT_URL="${DIRECT_URL:-http://192.168.16.1:8765}"
DISPATCH_URL="${DISPATCH_URL:-http://192.168.16.1:8767}"
DEVICE_ID="${DEVICE_ID:-r1-dev}"
REQUESTS="${REQUESTS:-5}"

echo "=== R1 Feign 链路基准线 ==="
echo "device-report : $DIRECT_URL"
echo "command-dispatch : $DISPATCH_URL"
echo ""

echo "--- 健康检查 ---"
curl -sf "$DIRECT_URL/actuator/health" | head -c 200
echo ""
curl -sf "$DISPATCH_URL/actuator/health" | head -c 200
echo ""
echo ""

echo "--- 发送 $REQUESTS 次 reports-with-dispatch ---"
for n in $(seq 1 "$REQUESTS"); do
  id="${DEVICE_ID}-${n}"
  echo "[$n/$REQUESTS] deviceId=$id"
  curl -s -w "\n  HTTP %{http_code}  time %{time_total}s\n" -X POST \
    "$DIRECT_URL/api/v1/devices/${id}/reports-with-dispatch" \
    -H "Content-Type: application/json" \
    -d '{"payload":{"temperature":25,"humidity":60}}'
  echo ""
done

echo "=== R1 完成 ==="
echo "验证："
echo "  1. 每次响应 HTTP 201，JSON 含 reportId 与 ackResponse.ackId"
echo "  2. Sentinel Dashboard → dispatchAck 通过 QPS > 0"
echo "  3. Prometheus: rate(http_server_requests_seconds_count{application=\"command-dispatch-service\"}[1m])"
