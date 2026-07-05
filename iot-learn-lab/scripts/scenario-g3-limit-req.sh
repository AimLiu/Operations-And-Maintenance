#!/usr/bin/env bash
# iot-learn-lab/scripts/scenario-g3-limit-req.sh
set -euo pipefail

GATEWAY_URL="${GATEWAY_URL:-http://localhost:9080}"
DURATION="${DURATION:-60}"

echo "=== G3 limit-req 限流实验 ==="
end=$((SECONDS + DURATION))
while [ $SECONDS -lt $end ]; do
  for _ in $(seq 1 50); do
    curl -s -o /dev/null -X POST "$GATEWAY_URL/api/v1/devices/g3-dev/reports" \
      -H "Content-Type: application/json" \
      -d '{"payload":{"temperature":25}}' &
  done
  wait
  sleep 0.05
done
echo "=== G3 完成：limit-req rate=10 burst=5，应有大量 429 ==="