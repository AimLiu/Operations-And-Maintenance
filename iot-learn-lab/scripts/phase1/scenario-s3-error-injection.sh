#!/usr/bin/env bash
# iot-learn-lab/scripts/scenario-s3-error-injection.sh
set -euo pipefail

BASE_URL="${BASE_URL:-http://192.168.16.1:8765}"
DURATION="${DURATION:-120}"

echo "=== S3 应用异常错误飙升 ==="
end=$((SECONDS + DURATION))
while [ $SECONDS -lt $end ]; do
  # 50% 正常请求
  curl -s -o /dev/null -X POST "$BASE_URL/api/v1/devices/device-err/reports" \
    -H "Content-Type: application/json" \
    -d '{"payload":{"temperature":25}}' &
  # 50% 错误请求
  curl -s -o /dev/null -X POST "$BASE_URL/api/v1/debug/error" &
  wait
  sleep 0.1
done
echo "=== S3 完成，检查错误率是否 > 5% ==="