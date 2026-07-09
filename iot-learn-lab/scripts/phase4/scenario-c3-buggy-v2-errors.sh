#!/usr/bin/env bash
# 场景 C3：v2 缺陷暴露 — 90/10 下总错误率略升，v2 5xx 显著高于 v1
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

GATEWAY_URL="${GATEWAY_URL:-http://localhost:9080}"
DIRECT_V2="${DIRECT_V2:-http://192.168.16.1:8766}"
ADMIN_API="${ADMIN_API:-http://localhost:9180}"
ADMIN_KEY="${ADMIN_KEY:-edd1c9f034335f136f87ad84b625c8f1}"
UPSTREAM_ID="${UPSTREAM_ID:-00000000000000000158}"
DURATION="${DURATION:-60}"
PROBE_SIZE="${PROBE_SIZE:-20}"
DEVICE_PREFIX="${DEVICE_PREFIX:-c3-bug}"

export ADMIN_API ADMIN_KEY UPSTREAM_ID

echo "=== C3 v2 缺陷暴露（金丝雀观测）==="
echo "网关 : $GATEWAY_URL"
echo "v2 直连 : $DIRECT_V2"
echo "压测时长 : ${DURATION}s"
echo ""
echo "前置："
echo "  [ ] v2 app.canary-bug-enabled=true（IDEA profile v2 或 Nacos 热更新）"
echo "  [ ] 已重启 v2 使 Service 层缺陷生效（确保 500 进入 http.server.requests）"
echo "  [ ] Prometheus 已 scrape 8766"
echo ""

echo "--- Step 1：直连 v2 冒烟 $PROBE_SIZE 次（约 50% 500）---"
v2_201=0
v2_5xx=0
for i in $(seq 1 "$PROBE_SIZE"); do
  code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    "$DIRECT_V2/api/v1/devices/${DEVICE_PREFIX}-direct-${i}/reports" \
    -H "Content-Type: application/json" \
    -d '{"payload":{"temperature":25}}')
  echo "  direct v2 [$i/$PROBE_SIZE] HTTP $code"
  if [ "$code" = "201" ]; then v2_201=$((v2_201 + 1)); elif [[ "$code" =~ ^5 ]]; then v2_5xx=$((v2_5xx + 1)); fi
done
echo "  v2 直连汇总: 201=$v2_201  5xx=$v2_5xx"
if [ "$v2_5xx" -eq 0 ]; then
  echo ""
  echo "  ⚠ 未观察到 5xx：请确认 canary-bug-enabled=true 且 v2 已重启"
fi
echo ""

echo "--- Step 2：确认 upstream 90/10 ---"
bash "$LAB_ROOT/infra/apisix/bootstrap-device-report-gateway.sh" none
bash "$LAB_ROOT/infra/apisix/bootstrap-canary-90-10.sh"
echo ""

echo "--- Step 3：经网关压测 ${DURATION}s ---"
export BASE_URL="$GATEWAY_URL"
export DURATION
bash "$SCRIPT_DIR/../phase1/scenario-s2-device-burst.sh"
echo ""

echo "=== C3 完成 ==="
echo "验证（压测结束后等待 30–60s 再查 Prometheus）："
echo "  1. v2 5xx rate >> v1 5xx rate"
echo "  2. 总错误率上升但可控（约 0.1 × v2 错误率，因仅 10% 流量到 v2）"
echo "  3. Grafana Canary 行：v2 错误率面板应明显高于 v1"
echo ""
echo "PromQL — v2 错误率："
echo '  sum(rate(http_server_requests_seconds_count{application="device-report-service",version="v2",status=~"5.."}[5m]))'
echo '  /'
echo '  sum(rate(http_server_requests_seconds_count{application="device-report-service",version="v2"}[5m]))'
echo ""
echo "PromQL — 总错误率："
echo '  sum(rate(http_server_requests_seconds_count{application="device-report-service",status=~"5.."}[5m]))'
echo '  /'
echo '  sum(rate(http_server_requests_seconds_count{application="device-report-service"}[5m]))'
echo ""
echo "PromQL — 分版本 5xx QPS："
echo '  sum(rate(http_server_requests_seconds_count{version="v1",status=~"5.."}[1m]))'
echo '  sum(rate(http_server_requests_seconds_count{version="v2",status=~"5.."}[1m]))'
