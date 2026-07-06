#!/usr/bin/env bash
# iot-learn-lab/scripts/scenario-s2-device-burst.sh
# 场景 S2：模拟 100 设备持续上报 60 秒
set -euo pipefail

BASE_URL="${BASE_URL:-http://192.168.16.1:8765}"
DURATION="${DURATION:-60}"

echo "=== S2 设备上报流量突增 ==="
echo "目标: $BASE_URL, 持续: ${DURATION}s"

end=$((SECONDS + DURATION))
while [ $SECONDS -lt $end ]; do
  for i in $(seq 1 100); do
    curl -s -o /dev/null -X POST "$BASE_URL/api/v1/devices/device-$i/reports" \
      -H "Content-Type: application/json" \
      -d "{\"payload\":{\"temperature\":$((20 + RANDOM % 15)),\"seq\":$SECONDS}}" &
  done
  wait
  sleep 0.2
done

echo "=== S2 完成，请在 Grafana 查看 QPS 与 P99 ==="