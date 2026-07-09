#!/usr/bin/env bash
# 场景 C2：APISIX 90/10 金丝雀分流验证 — 经网关压测，v1:v2 QPS ≈ 9:1
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

GATEWAY_URL="${GATEWAY_URL:-http://localhost:9080}"
ADMIN_API="${ADMIN_API:-http://localhost:9180}"
ADMIN_KEY="${ADMIN_KEY:-edd1c9f034335f136f87ad84b625c8f1}"
UPSTREAM_ID="${UPSTREAM_ID:-00000000000000000158}"
DURATION="${DURATION:-60}"
SAMPLE_SIZE="${SAMPLE_SIZE:-100}"
DEVICE_PREFIX="${DEVICE_PREFIX:-c2-split}"

export ADMIN_API ADMIN_KEY UPSTREAM_ID

echo "=== C2 金丝雀 90/10 分流验证 ==="
echo "网关 : $GATEWAY_URL"
echo "压测时长 : ${DURATION}s"
echo ""
echo "前置："
echo "  [ ] C1 已通过（v1/v2 均 healthy）"
echo "  [ ] C2 建议 v2 canary-bug-enabled=false，避免 5xx 干扰分流观测"
echo "  [ ] APISIX Admin API 可从 WSL 访问（$ADMIN_API）"
echo ""

echo "--- Step 1：关闭网关限流插件（避免与发布观测混淆）---"
bash "$LAB_ROOT/infra/apisix/bootstrap-device-report-gateway.sh" none
echo ""

echo "--- Step 2：upstream 权重 90/10 ---"
bash "$LAB_ROOT/infra/apisix/bootstrap-canary-90-10.sh"
echo ""

echo "--- Step 3：网关健康抽样 $SAMPLE_SIZE 次 ---"
codes_file="$(mktemp)"
for i in $(seq 1 "$SAMPLE_SIZE"); do
  code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    "$GATEWAY_URL/api/v1/devices/${DEVICE_PREFIX}-${i}/reports" \
    -H "Content-Type: application/json" \
    -d '{"payload":{"temperature":25}}')
  echo "$code" >> "$codes_file"
done
echo "HTTP 状态分布："
sort "$codes_file" | uniq -c | sed 's/^/  /'
rm -f "$codes_file"
echo "  （C2 bug 关闭时应几乎全是 201；分流比例请用 Prometheus 按 version 查看）"
echo ""

echo "--- Step 4：经网关持续压测 ${DURATION}s ---"
export BASE_URL="$GATEWAY_URL"
export DURATION
bash "$SCRIPT_DIR/../phase1/scenario-s2-device-burst.sh"
echo ""

echo "=== C2 完成 ==="
echo "验证（等待 1–2 分钟后在 Grafana / Prometheus 查看）："
echo "  1. v1 QPS ≈ 9 × v2 QPS（统计窗口 1–5min）"
echo "  2. 两版本均有非零 QPS"
echo "  3. 网关入口 QPS 与压测强度一致"
echo ""
echo "PromQL："
echo '  sum(rate(http_server_requests_seconds_count{application="device-report-service",version="v1"}[1m]))'
echo '  sum(rate(http_server_requests_seconds_count{application="device-report-service",version="v2"}[1m]))'
echo '  sum(rate(apisix_http_latency_count{type="request",route="device-report-service"}[1m]))'
echo ""
echo "比例参考（v2 占 v1+v2 总量）："
echo '  sum(rate(http_server_requests_seconds_count{version="v2"}[5m]))'
echo '  /'
echo '  sum(rate(http_server_requests_seconds_count{application="device-report-service"}[5m]))'
echo "  预期 ≈ 0.10（± 采样误差）"
