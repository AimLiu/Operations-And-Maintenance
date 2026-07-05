#!/usr/bin/env bash
# iot-learn-lab/scripts/scenario-g2-limit-count.sh
set -euo pipefail

GATEWAY_URL="${GATEWAY_URL:-http://localhost:9080}"
DURATION="${DURATION:-90}"

echo "=== G2 limit-count 限流实验 ==="
echo "网关: $GATEWAY_URL, 持续: ${DURATION}s"
echo "预期: 429 数量上升，应用 QPS 被压制"

end=$((SECONDS + DURATION))
total=0
count_429=0
count_ok=0

while [ $SECONDS -lt $end ]; do
  for i in $(seq 1 20); do
    code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
      "$GATEWAY_URL/api/v1/devices/g2-${i}/reports" \
      -H "Content-Type: application/json" \
      -d "{\"payload\":{\"temperature\":$((20 + RANDOM % 10)),\"seq\":$SECONDS}}")
    total=$((total + 1))
    if [ "$code" = "429" ]; then count_429=$((count_429 + 1)); else count_ok=$((count_ok + 1)); fi
  done
  sleep 0.5
done

echo "=== 结果: total=$total ok=$count_ok 429=$count_429 ==="
echo "请在 Grafana 对比：apisix_http_latency_count{type=\"request\"} vs 应用 QPS（429 不进 apisix_http_status，见 iot-learn-lab/docs/phase2-apisix-prometheus-setup.md）"