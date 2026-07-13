#!/usr/bin/env bash
# 场景 E2：异步路径 10x 流量突增 — Kafka 削峰，API 应快速 202
set -euo pipefail

DIRECT_URL="${DIRECT_URL:-http://192.168.16.1:8765}"
DURATION="${DURATION:-60}"
DEVICES_PER_ROUND="${DEVICES_PER_ROUND:-1000}"
DEVICE_PREFIX="${DEVICE_PREFIX:-e2-async}"
SLEEP_SEC="${SLEEP_SEC:-0.2}"
SAMPLE_SIZE="${SAMPLE_SIZE:-50}"

echo "=== E2 异步 10x 流量突增 ==="
echo "目标     : $DIRECT_URL/api/v1/devices/{id}/reports-async"
echo "持续     : ${DURATION}s"
echo "每轮设备 : $DEVICES_PER_ROUND"
echo ""
echo "前置："
echo "  [ ] device-report-service :8765 已启动，Kafka 可连 192.168.19.64:9092"
echo "  [ ] Topic device-report-events 已创建"
echo "  [ ] device-report-consumer :8768 建议运行（否则 lag 会升，API 仍可为 202）"
echo ""

echo "--- 健康检查 ---"
curl -sf "$DIRECT_URL/actuator/health" | head -c 200
echo ""
echo ""

echo "--- 抽样 $SAMPLE_SIZE 次（看 HTTP 202 比例）---"
codes_file="$(mktemp)"
for i in $(seq 1 "$SAMPLE_SIZE"); do
  code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    "$DIRECT_URL/api/v1/devices/${DEVICE_PREFIX}-sample-${i}/reports-async" \
    -H "Content-Type: application/json" \
    -d '{"payload":{"temperature":25,"humidity":60}}')
  echo "$code" >> "$codes_file"
done
echo "HTTP 状态分布："
sort "$codes_file" | uniq -c | sed 's/^/  /'
rm -f "$codes_file"
echo "  （预期几乎全是 202）"
echo ""

echo "--- 压测开始 ---"
end=$((SECONDS + DURATION))
total=0
while [ "$SECONDS" -lt "$end" ]; do
  for i in $(seq 1 "$DEVICES_PER_ROUND"); do
    id="${DEVICE_PREFIX}-${SECONDS}-${i}"
    curl -s -o /dev/null -X POST \
      "$DIRECT_URL/api/v1/devices/${id}/reports-async" \
      -H "Content-Type: application/json" \
      -d "{\"payload\":{\"temperature\":$((20 + RANDOM % 15)),\"seq\":$SECONDS}}" &
    total=$((total + 1))
  done
  wait
  sleep "$SLEEP_SEC"
done

echo "压测结束，约发起请求: $total"
echo ""
echo "=== E2 完成 ==="
echo "验证（Grafana / Prometheus / Offset Explorer，等待 1–2 分钟）："
echo "  1. 异步 API P99 应明显低于 E1 同步路径"
echo "  2. HTTP 202 rate 占主导"
echo "  3. spring_kafka_template_seconds_count 增长"
echo "  4. consumer 运行时 lag 可能短暂升高后下降（E3 重点）"
echo ""
echo "PromQL："
echo '  sum(rate(http_server_requests_seconds_count{application="device-report-service",uri=~".*reports-async",status="202"}[1m]))'
echo '  histogram_quantile(0.99, sum(rate(http_server_requests_seconds_bucket{application="device-report-service",uri=~".*reports-async"}[1m])) by (le))'
echo '  sum(rate(spring_kafka_template_seconds_count{application="device-report-service",result="success"}[1m]))'
echo '  hikaricp_connections_pending{application="device-report-service"}'
