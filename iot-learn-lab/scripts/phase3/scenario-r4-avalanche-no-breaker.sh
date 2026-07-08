#!/usr/bin/env bash
# 场景 R4：雪崩对照组 — 无熔断，下游不可用导致上游阻塞
set -euo pipefail

DIRECT_URL="${DIRECT_URL:-http://192.168.16.1:8765}"
DURATION="${DURATION:-60}"
CONCURRENCY="${CONCURRENCY:-20}"

echo "=== R4 雪崩对照组（无熔断）==="
echo "目标: $DIRECT_URL"
echo "持续: ${DURATION}s, 每轮并发: $CONCURRENCY"
echo ""
echo "实验前检查清单："
echo "  [ ] Nacos 中已删除或清空 device-report-service-degrade-rules"
echo "  [ ] application.yml 中 feign.sentinel.enabled=false（或临时注释）"
echo "  [ ] CommandDispatchClient 已临时去掉 fallback（否则快速降级，看不到雪崩）"
echo "  [ ] command-dispatch-service 已在 IDEA 中 Stop"
echo "  [ ] 已配置 Feign connectTimeout/readTimeout（建议 3s/10s）"
echo ""
echo "确认以上完成后按 Enter 继续 ..."
read -r _

stats_file="$(mktemp)"
time_file="$(mktemp)"
trap 'rm -f "$stats_file" "$time_file"' EXIT

end=$((SECONDS + DURATION))
while [ $SECONDS -lt $end ]; do
  for i in $(seq 1 "$CONCURRENCY"); do
    {
      code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 120 -X POST \
        "$DIRECT_URL/api/v1/devices/r4-${i}/reports-with-dispatch" \
        -H "Content-Type: application/json" \
        -d '{"payload":{"temperature":25}}')
      echo "$code"
    } >>"$stats_file" &
    curl -s -o /dev/null -w "%{time_total}\n" --max-time 120 -X POST \
      "$DIRECT_URL/api/v1/devices/r4-time-${i}/reports-with-dispatch" \
      -H "Content-Type: application/json" \
      -d '{"payload":{"temperature":25}}' >>"$time_file" &
  done
  wait
done

echo "--- HTTP 状态码统计 ---"
sort "$stats_file" | uniq -c | sort -rn

if [ -s "$time_file" ]; then
  echo "--- 响应耗时样本（秒）---"
  sort -n "$time_file" | awk '
    { a[NR]=$1; sum+=$1 }
    END {
      if (NR==0) exit
      printf "  min=%.3f  max=%.3f  avg=%.3f  p50=%.3f\n",
        a[1], a[NR], sum/NR, a[int(NR*0.5)+1]
    }'
fi

echo ""
echo "=== R4 完成 ==="
echo "验证（坏现象）："
echo "  1. time_total 明显偏大（接近 Feign readTimeout）"
echo "  2. Grafana: device-report P99 升高，jvm_threads_live 可能上升"
echo "  3. command-dispatch Target DOWN，report QPS 仍高但响应慢"
