#!/usr/bin/env bash
# 场景 R5：雪崩保护组 — Sentinel degrade + Feign fallback 快速失败
set -euo pipefail

DIRECT_URL="${DIRECT_URL:-http://192.168.16.1:8765}"
DURATION="${DURATION:-60}"
CONCURRENCY="${CONCURRENCY:-20}"

echo "=== R5 雪崩保护组（有熔断 + fallback）==="
echo "目标: $DIRECT_URL"
echo "持续: ${DURATION}s, 每轮并发: $CONCURRENCY"
echo ""
echo "实验前检查清单："
echo "  [ ] Nacos 已恢复 device-report-service-degrade-rules"
echo "  [ ] feign.sentinel.enabled=true"
echo "  [ ] CommandDispatchClient fallback=DispatchFallbackHandler 已启用"
echo "  [ ] command-dispatch-service 已 Stop"
echo ""
echo "确认后按 Enter 继续 ..."
read -r _

stats_file="$(mktemp)"
body_file="$(mktemp)"
time_file="$(mktemp)"
trap 'rm -f "$stats_file" "$body_file" "$time_file"' EXIT

end=$((SECONDS + DURATION))
while [ $SECONDS -lt $end ]; do
  for i in $(seq 1 "$CONCURRENCY"); do
    curl -s -o /dev/null -w "%{http_code}\n" -X POST \
      "$DIRECT_URL/api/v1/devices/r5-${i}/reports-with-dispatch" \
      -H "Content-Type: application/json" \
      -d '{"payload":{"temperature":25}}' >>"$stats_file" &
    curl -s -w "%{time_total}\n" -X POST \
      "$DIRECT_URL/api/v1/devices/r5-sample/reports-with-dispatch" \
      -H "Content-Type: application/json" \
      -d '{"payload":{"temperature":25}}' >>"$time_file" 2>/dev/null &
  done
  wait
done

curl -s -X POST \
  "$DIRECT_URL/api/v1/devices/r5-check/reports-with-dispatch" \
  -H "Content-Type: application/json" \
  -d '{"payload":{"temperature":25}}' >"$body_file"

echo "--- HTTP 状态码统计 ---"
sort "$stats_file" | uniq -c | sort -rn

if [ -s "$time_file" ]; then
  echo "--- 响应耗时样本（秒）---"
  sort -n "$time_file" | awk '
    { a[NR]=$1; sum+=$1 }
    END {
      if (NR==0) exit
      printf "  min=%.3f  max=%.3f  avg=%.3f\n", a[1], a[NR], sum/NR
    }'
fi

echo "--- 采样响应体 ---"
head -c 500 "$body_file"
echo ""

echo ""
echo "=== R5 完成 ==="
echo "验证（好现象）："
echo "  1. HTTP 多为 201，ackResponse.result=DEGRADED 或 ackId 以 fallback- 开头"
echo "  2. time_total 显著小于 R4（毫秒~百毫秒级）"
echo "  3. Sentinel Dashboard → 降级/熔断相关指标；dispatch QPS ≈ 0"
