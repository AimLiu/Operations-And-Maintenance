#!/usr/bin/env bash
# iot-learn-lab/scripts/scenario-g1-gateway-baseline.sh
# 场景 G1：经 APISIX 网关压测（复用 S2 逻辑，默认 GATEWAY_URL）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export BASE_URL="${GATEWAY_URL:-http://localhost:9080}"
export DURATION="${DURATION:-60}"

echo "=== G1 网关基准压测 ==="
echo "网关: $BASE_URL"
"$SCRIPT_DIR/scenario-s2-device-burst.sh"
echo "=== G1 完成：对比 Grafana 网关 QPS vs 应用 QPS ==="