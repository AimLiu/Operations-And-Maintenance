#!/usr/bin/env bash
# 场景 R2：Sentinel 流控 block — Nacos flow 规则 QPS=5
set -euo pipefail

DIRECT_URL="${DIRECT_URL:-http://192.168.16.1:8765}"
DURATION="${DURATION:-60}"
CONCURRENCY="${CONCURRENCY:-10}"

echo "=== R2 Sentinel flow block ==="
echo "目标: $DIRECT_URL"
echo "持续: ${DURATION}s, 每轮并发: $CONCURRENCY"
echo "前置: Nacos 已配置 device-report-service-flow-rules (QPS=5)"
echo ""

stats_file="$(mktemp)"
trap 'rm -f "$stats_file"' EXIT

end=$((SECONDS + DURATION))
while [ $SECONDS -lt $end ]; do
  for i in $(seq 1 "$CONCURRENCY"); do
    curl -s -o /dev/null -w "%{http_code}\n" -X POST \
      "$DIRECT_URL/api/v1/devices/r2-${i}/reports-with-dispatch" \
      -H "Content-Type: application/json" \
      -d '{"payload":{"temperature":25}}' >>"$stats_file" &
  done
  wait
  sleep 0.2
done

echo "--- HTTP 状态码统计 ---"
sort "$stats_file" | uniq -c | sort -rn

echo ""
echo "=== R2 完成 ==="
echo "验证："
echo "  1. 201（通过）与 429（block）混合；201 约 ≤5 QPS"
echo "  2. Sentinel Dashboard → dispatchAck Block QPS > 0"
echo "  3. command-dispatch QPS 约 ≤ 5"
