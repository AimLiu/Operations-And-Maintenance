#!/usr/bin/env bash
# 场景 E1：同步路径 10x 流量突增 — 直写 PostgreSQL，观察 HikariCP pending / P99
set -euo pipefail

DIRECT_URL="${DIRECT_URL:-http://192.168.16.1:8765}"
DURATION="${DURATION:-60}"
DEVICES_PER_ROUND="${DEVICES_PER_ROUND:-1000}"
DEVICE_PREFIX="${DEVICE_PREFIX:-e1-sync}"
SLEEP_SEC="${SLEEP_SEC:-0.2}"

echo "=== E1 同步 10x 流量突增 ==="
echo "目标     : $DIRECT_URL/api/v1/devices/{id}/reports"
echo "持续     : ${DURATION}s"
echo "每轮设备 : $DEVICES_PER_ROUND（约为 S2 基准 100 的 10 倍）"
echo ""
echo "前置："
echo "  [ ] device-report-service :8765 已启动"
echo "  [ ] consumer 是否运行不影响本场景（走同步写库）"
echo ""

echo "--- 健康检查 ---"
curl -sf "$DIRECT_URL/actuator/health" | head -c 200
echo ""
echo ""

echo "--- 压测开始 ---"
end=$((SECONDS + DURATION))
total=0
while [ "$SECONDS" -lt "$end" ]; do
  for i in $(seq 1 "$DEVICES_PER_ROUND"); do
    id="${DEVICE_PREFIX}-${SECONDS}-${i}"
    curl -s -o /dev/null -X POST \
      "$DIRECT_URL/api/v1/devices/${id}/reports" \
      -H "Content-Type: application/json" \
      -d "{\"payload\":{\"temperature\":$((20 + RANDOM % 15)),\"seq\":$SECONDS}}" &
    total=$((total + 1))
  done
  wait
  sleep "$SLEEP_SEC"
done

echo "压测结束，约发起请求: $total"
echo ""
echo "=== E1 完成 ==="
echo "验证（Grafana / Prometheus，等待 1–2 分钟）："
echo "  1. HikariCP pending / active 升高"
echo "  2. 同步 API P99 恶化，可能出现 5xx 或慢响应"
echo "  3. 对比 E2 异步路径，同步路径更易打满连接池"
echo ""
echo "PromQL："
echo '  hikaricp_connections_pending{application="device-report-service"}'
echo '  hikaricp_connections_active{application="device-report-service"}'
echo '  histogram_quantile(0.99, sum(rate(http_server_requests_seconds_bucket{application="device-report-service",uri=~".*/reports"}[1m])) by (le))'
