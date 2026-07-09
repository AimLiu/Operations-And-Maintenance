#!/usr/bin/env bash
# 场景 C4：回滚至 v1 — upstream 权重 100/0 后，v2 QPS→0，总错误率恢复
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

GATEWAY_URL="${GATEWAY_URL:-http://localhost:9080}"
DIRECT_V1="${DIRECT_V1:-http://192.168.16.1:8765}"
ADMIN_API="${ADMIN_API:-http://localhost:9180}"
ADMIN_KEY="${ADMIN_KEY:-edd1c9f034335f136f87ad84b625c8f1}"
UPSTREAM_ID="${UPSTREAM_ID:-00000000000000000158}"
DURATION="${DURATION:-60}"
SAMPLE_SIZE="${SAMPLE_SIZE:-50}"
DEVICE_PREFIX="${DEVICE_PREFIX:-c4-rollback}"

export ADMIN_API ADMIN_KEY UPSTREAM_ID

echo "=== C4 金丝雀回滚至 v1 ==="
echo "网关 : $GATEWAY_URL"
echo "v1 直连 : $DIRECT_V1"
echo "压测时长 : ${DURATION}s"
echo ""
echo "前置："
echo "  [ ] 已完成 C3（v2 bug 仍开启亦可，回滚后用户侧不应再打到 v2）"
echo "  [ ] v1 实例 healthy"
echo ""

echo "--- Step 1：执行回滚脚本（100% v1 / 0% v2）---"
bash "$LAB_ROOT/infra/apisix/bootstrap-canary-rollback.sh"
echo ""

echo "--- Step 2：网关抽样 $SAMPLE_SIZE 次 ---"
ok=0
err=0
for i in $(seq 1 "$SAMPLE_SIZE"); do
  code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    "$GATEWAY_URL/api/v1/devices/${DEVICE_PREFIX}-${i}/reports" \
    -H "Content-Type: application/json" \
    -d '{"payload":{"temperature":25}}')
  if [ "$code" = "201" ]; then ok=$((ok + 1)); else err=$((err + 1)); fi
done
echo "  抽样汇总: 201=$ok  其他=$err"
echo "  （v2 bug 仍开时，回滚后网关侧应几乎不再出现 500）"
echo ""

echo "--- Step 3：确认 v1 直连仍正常 ---"
curl -sf "$DIRECT_V1/actuator/health" | head -c 200
echo ""
echo ""

echo "--- Step 4：经网关压测 ${DURATION}s ---"
export BASE_URL="$GATEWAY_URL"
export DURATION
bash "$SCRIPT_DIR/../phase1/scenario-s2-device-burst.sh"
echo ""

echo "=== C4 完成 ==="
echo "验证（等待 1–2 分钟）："
echo "  1. v2 QPS ≈ 0（仅 v1 接收网关流量）"
echo "  2. 总错误率回落至 C2 水平（不再受 v2 5xx 拖累）"
echo "  3. v2 进程可保留观察，无需立即停止"
echo ""
echo "PromQL — v2 应趋近 0："
echo '  sum(rate(http_server_requests_seconds_count{application="device-report-service",version="v2"}[1m]))'
echo ""
echo "PromQL — v1 承担全部入口："
echo '  sum(rate(http_server_requests_seconds_count{application="device-report-service",version="v1"}[1m]))'
echo ""
echo "PromQL — 总错误率恢复："
echo '  sum(rate(http_server_requests_seconds_count{application="device-report-service",status=~"5.."}[5m]))'
echo '  /'
echo '  sum(rate(http_server_requests_seconds_count{application="device-report-service"}[5m]))'
echo ""
echo "说明：C4 是流量回滚（APISIX 权重）；关闭 v2 bug 需改 canary-bug-enabled（见 C6 / Nacos 热更新）"
