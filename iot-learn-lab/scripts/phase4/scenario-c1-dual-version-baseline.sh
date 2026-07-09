#!/usr/bin/env bash
# 场景 C1：双版本基准 — v1/v2 同时健康，直连冒烟（不经网关）
set -euo pipefail

DIRECT_V1="${DIRECT_V1:-http://192.168.16.1:8765}"
DIRECT_V2="${DIRECT_V2:-http://192.168.16.1:8766}"
NACOS_ADDR="${NACOS_ADDR:-192.168.19.64:8848}"
REQUESTS="${REQUESTS:-5}"
DEVICE_PREFIX="${DEVICE_PREFIX:-c1-dev}"

echo "=== C1 双版本基准线 ==="
echo "v1 : $DIRECT_V1"
echo "v2 : $DIRECT_V2"
echo "Nacos : $NACOS_ADDR"
echo ""
echo "前置（本场景）："
echo "  [ ] Windows 上 v1(:8765) 与 v2(:8766) 均已启动"
echo "  [ ] v2 Active Profiles = v2（不是 application-v2.yml）"
echo "  [ ] C1 建议 v2 关闭缺陷：app.canary-bug-enabled=false（或 Nacos 热更新）"
echo "  [ ] Prometheus 已 scrape 8765 + 8766"
echo ""

echo "--- 健康检查 ---"
curl -sf "$DIRECT_V1/actuator/health" | head -c 300
echo ""
curl -sf "$DIRECT_V2/actuator/health" | head -c 300
echo ""
echo ""

echo "--- Nacos 实例列表 ---"
nacos_url="http://${NACOS_ADDR}/nacos/v1/ns/instance/list"
nacos_qs="serviceName=device-report-service&namespaceId=public&groupName=DEFAULT_GROUP"
if curl -sf "${nacos_url}?${nacos_qs}" | jq -e '.hosts | length >= 2' >/dev/null 2>&1; then
  curl -sf "${nacos_url}?${nacos_qs}" | jq -r '.hosts[] | "  \(.ip):\(.port) healthy=\(.healthy) version=\(.metadata.version // "n/a")"'
else
  curl -sf "${nacos_url}?${nacos_qs}" | head -c 500
  echo ""
  echo "  （提示：需 jq 且 Nacos 中应有 8765 + 8766 两个 healthy 实例）"
fi
echo ""

echo "--- 直连 v1：发送 $REQUESTS 次 reports ---"
v1_ok=0
v1_err=0
for n in $(seq 1 "$REQUESTS"); do
  id="${DEVICE_PREFIX}-v1-${n}"
  code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    "$DIRECT_V1/api/v1/devices/${id}/reports" \
    -H "Content-Type: application/json" \
    -d '{"payload":{"temperature":25,"humidity":60}}')
  echo "  [$n/$REQUESTS] deviceId=$id HTTP $code"
  if [ "$code" = "201" ]; then v1_ok=$((v1_ok + 1)); else v1_err=$((v1_err + 1)); fi
done
echo "  v1 汇总: 201=$v1_ok  其他=$v1_err"
echo ""

echo "--- 直连 v2：发送 $REQUESTS 次 reports ---"
v2_ok=0
v2_err=0
for n in $(seq 1 "$REQUESTS"); do
  id="${DEVICE_PREFIX}-v2-${n}"
  code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    "$DIRECT_V2/api/v1/devices/${id}/reports" \
    -H "Content-Type: application/json" \
    -d '{"payload":{"temperature":25,"humidity":60}}')
  echo "  [$n/$REQUESTS] deviceId=$id HTTP $code"
  if [ "$code" = "201" ]; then v2_ok=$((v2_ok + 1)); else v2_err=$((v2_err + 1)); fi
done
echo "  v2 汇总: 201=$v2_ok  其他=$v2_err"
echo ""

echo "--- Prometheus 版本标签快检（本机 metrics）---"
echo "v1:"
curl -sf "$DIRECT_V1/actuator/prometheus" 2>/dev/null | grep -m1 'http_server_requests_seconds_count{.*version="v1"' || echo "  （未找到 version=v1 样本，请确认 management.metrics.tags.version）"
echo "v2:"
curl -sf "$DIRECT_V2/actuator/prometheus" 2>/dev/null | grep -m1 'http_server_requests_seconds_count{.*version="v2"' || echo "  （未找到 version=v2 样本）"
echo ""

echo "=== C1 完成 ==="
echo "验证："
echo "  1. Nacos 可见 8765(v1) + 8766(v2)，均为 healthy"
echo "  2. canary-bug-enabled=false 时，直连 v1/v2 均应 201"
echo "  3. Prometheus Targets：8765、8766 均为 UP"
echo ""
echo "PromQL："
echo '  up{job="device-report-service"}'
echo '  http_server_requests_seconds_count{application="device-report-service",version="v1"}'
echo '  http_server_requests_seconds_count{application="device-report-service",version="v2"}'
