#!/usr/bin/env bash
# iot-learn-lab/scripts/scenario-g5-upstream-timeout.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATEWAY_URL="${GATEWAY_URL:-http://localhost:9080}"

echo "=== G5 上游超时 + 慢查询 ==="
echo "1) 经网关触发 5s 慢查询（网关 read timeout=3s）"
code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  "${GATEWAY_URL}/api/v1/debug/slow-query?seconds=5")
echo "slow-query via gateway: HTTP $code (expect 502/504)"

echo "2) 叠加正常上报流量 60s"
export BASE_URL="$GATEWAY_URL"
export DURATION=60
"$SCRIPT_DIR/scenario-s2-device-burst.sh"

echo "=== G5 完成：查看网关 502/504 与 HikariCP pending ==="