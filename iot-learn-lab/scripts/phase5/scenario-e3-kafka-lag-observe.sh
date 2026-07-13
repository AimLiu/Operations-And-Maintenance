#!/usr/bin/env bash
# 场景 E3：Kafka lag 先升后降 — 停 consumer 压测 → 启动 consumer 观察积压消化
set -euo pipefail

DIRECT_URL="${DIRECT_URL:-http://192.168.16.1:8765}"
CONSUMER_URL="${CONSUMER_URL:-http://192.168.16.1:8768}"
KAFKA_CONTAINER="${KAFKA_CONTAINER:-kafka-learn}"
CONSUMER_GROUP="${KAFKA_CONSUMER_GROUP_ID:-device-report-consumer-group}"
KAFKA_TOPIC="${KAFKA_TOPIC:-device-report-events}"

DURATION="${DURATION:-30}"
DEVICES_PER_ROUND="${DEVICES_PER_ROUND:-500}"
DEVICE_PREFIX="${DEVICE_PREFIX:-e3-lag}"
SLEEP_SEC="${SLEEP_SEC:-0.2}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"
MAX_WAIT_SEC="${MAX_WAIT_SEC:-600}"

describe_group() {
  docker exec "$KAFKA_CONTAINER" /opt/kafka/bin/kafka-consumer-groups.sh \
    --bootstrap-server 127.0.0.1:9092 \
    --describe \
    --group "$CONSUMER_GROUP" 2>/dev/null || true
}

sum_lag() {
  describe_group | awk '$3 ~ /^[0-9]+$/ { sum += $6 } END { print sum + 0 }'
}

print_lag_table() {
  echo "  --- consumer group: $CONSUMER_GROUP ---"
  describe_group | awk 'NR==1 || $3 ~ /^[0-9]+$/ { printf "  %s\n", $0 }'
  echo "  --- total LAG: $(sum_lag) ---"
}

echo "=== E3 Kafka lag 观测（先升后降）==="
echo "Producer : $DIRECT_URL/reports-async"
echo "Consumer : $CONSUMER_URL（Windows IDEA）"
echo "Kafka    : docker 容器 $KAFKA_CONTAINER"
echo "Group    : $CONSUMER_GROUP"
echo "Topic    : $KAFKA_TOPIC"
echo ""
echo "前置："
echo "  [ ] Kafka 容器已启动（docker ps | grep $KAFKA_CONTAINER）"
echo "  [ ] device-report-service :8765 正常"
echo "  [ ] 本脚本会提示你手动停/启 consumer :8768"
echo ""

if ! docker ps --format '{{.Names}}' | grep -qx "$KAFKA_CONTAINER"; then
  echo "错误：未找到 Kafka 容器 $KAFKA_CONTAINER"
  echo "请先启动：cd iot-learn-lab/infra/kafka && docker compose up -d"
  exit 1
fi

echo "--- 健康检查 ---"
curl -sf "$DIRECT_URL/actuator/health" | head -c 200
echo ""
if curl -sf "$CONSUMER_URL/actuator/health" >/dev/null 2>&1; then
  echo "Consumer 当前: UP（下一步请先停止 consumer）"
else
  echo "Consumer 当前: 不可达（可能已停止，可直接进入压测）"
fi
echo ""

echo "--- Step 1：停止 consumer ---"
echo "请在 IDEA 中停止 device-report-consumer（:8768），然后按 Enter"
read -r _

if curl -sf "$CONSUMER_URL/actuator/health" >/dev/null 2>&1; then
  echo "警告：consumer 仍可访问，lag 可能不会明显上升"
else
  echo "Consumer 已停止，继续"
fi
echo ""

echo "--- Step 2：异步压测 ${DURATION}s（每轮 ${DEVICES_PER_ROUND} 设备）---"
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

echo "--- Step 3：查看 lag 峰值（消费暂停期间）---"
sleep 2
peak_lag="$(sum_lag)"
print_lag_table
if [ "$peak_lag" -eq 0 ]; then
  echo ""
  echo "  ⚠ LAG 仍为 0，可能原因："
  echo "    - consumer 未真正停止"
  echo "    - 压测请求未成功（检查 producer 日志 / HTTP 202）"
  echo "    - consumer group 尚未创建（可先启动 consumer 再停，重跑本脚本）"
fi
echo ""

echo "--- Step 4：启动 consumer 并观察 lag 下降 ---"
echo "请在 IDEA 中启动 device-report-consumer（:8768），然后按 Enter"
read -r _

wait_start=$SECONDS
echo "每 ${POLL_INTERVAL}s 刷新一次 LAG（最多 ${MAX_WAIT_SEC}s）..."
echo ""

while true; do
  elapsed=$((SECONDS - wait_start))
  lag="$(sum_lag)"
  ts="$(date '+%H:%M:%S')"
  echo "[$ts] elapsed=${elapsed}s  total_LAG=$lag"
  print_lag_table
  echo ""

  if [ "$lag" -eq 0 ]; then
    echo "LAG 已降为 0，消费追平。"
    break
  fi
  if [ "$elapsed" -ge "$MAX_WAIT_SEC" ]; then
    echo "已达最大等待时间 ${MAX_WAIT_SEC}s，LAG=$lag，请检查 consumer 日志。"
    exit 1
  fi
  sleep "$POLL_INTERVAL"
done

echo ""
echo "=== E3 完成 ==="
echo "验证："
echo "  1. Step 3 时 total LAG > 0（consumer 停止期间）"
echo "  2. Step 4 中 LAG 单调下降至 0"
echo "  3. Offset Explorer 中同一 consumer group 的 Lag 标签变化一致"
echo ""
echo "说明："
echo "  - LAG = LOG-END-OFFSET - CURRENT-OFFSET（消费积压）"
echo "  - API 仍 202 不代表已落库；lag 下降才表示 consumer 在追平"
echo ""
echo "PromQL（若 consumer 暴露 kafka 指标）："
echo '  sum(kafka_consumer_fetch_manager_records_lag{application="device-report-consumer"})'
