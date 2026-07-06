#!/usr/bin/env bash
# iot-learn-lab/scripts/scenario-g6-downstream-down.sh
set -euo pipefail

GATEWAY_URL="${GATEWAY_URL:-http://localhost:9080}"

echo "=== G6 下游宕机 + 熔断 ==="
echo "请先在 Windows 停止 device-report-service，然后按 Enter 继续"
read -r _

echo "发送 10 个请求观察熔断..."
for i in $(seq 1 10); do
  code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    "$GATEWAY_URL/api/v1/devices/down-${i}/reports" \
    -H "Content-Type: application/json" \
    -d '{"payload":{"temperature":25}}')
  echo "request $i: HTTP $code"
  sleep 0.5
done

echo "=== 预期: 前几次 502/504，之后 503（熔断打开）==="
echo "恢复服务后等待 30s，再 curl 验证熔断关闭"