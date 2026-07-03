#!/usr/bin/env bash
# iot-learn-lab/scripts/scenario-s4-db-pressure.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_URL="${BASE_URL:-http://192.168.16.1:8765}"

echo "=== S4 数据库连接池压力 ==="
echo "目标: $BASE_URL"
echo "先启动 10 个慢查询（每个占连接 5 秒）..."

for _ in $(seq 1 10); do
  curl -s -o /dev/null -X POST "$BASE_URL/api/v1/debug/slow-query?seconds=5" &
done

sleep 2
echo "慢查询已占用连接池，现在叠加正常流量..."
DURATION=60 BASE_URL="$BASE_URL" "$SCRIPT_DIR/scenario-s2-device-burst.sh"

echo "=== S4 完成，检查 hikaricp_connections_pending 是否 > 0 ==="
