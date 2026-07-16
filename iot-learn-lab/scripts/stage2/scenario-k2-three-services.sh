#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "${SCRIPT_DIR}/env.sh"

NS="${K8S_NAMESPACE}"
REPORT_SVC="device-report-service"
LOCAL_PORT=8765
TS="$(date +%s)"

echo "== K2: three services on minikube =="

for dep in device-report-service command-dispatch-service device-report-consumer; do
  kubectl rollout status "deployment/${dep}" -n "$NS" --timeout=120s
done

kubectl get pods -n "$NS" -o wide

kubectl port-forward -n "$NS" "svc/${REPORT_SVC}" "${LOCAL_PORT}:8765" &
PF_PID=$!
trap 'kill $PF_PID 2>/dev/null || true' EXIT
sleep 3

echo "-- health (report) --"
curl -sf "http://127.0.0.1:${LOCAL_PORT}/actuator/health" | head -c 300
echo

echo "-- sync POST .../reports --"
DEVICE_SYNC="k2-sync-${TS}"
curl -sf -X POST "http://127.0.0.1:${LOCAL_PORT}/api/v1/devices/${DEVICE_SYNC}/reports" \
  -H "Content-Type: application/json" \
  -d "{\"payload\":{\"temp\":21,\"source\":\"k2-sync\"}}"
echo

echo "-- Feign POST .../reports-with-dispatch --"
DEVICE_FEIGN="k2-feign-${TS}"
RESP_FEIGN="$(curl -sf -X POST \
  "http://127.0.0.1:${LOCAL_PORT}/api/v1/devices/${DEVICE_FEIGN}/reports-with-dispatch" \
  -H "Content-Type: application/json" \
  -d "{\"payload\":{\"temp\":22,\"source\":\"k2-feign\"}}")"
echo "$RESP_FEIGN"
# 成功时应带上 dispatch 结果；fallback 时通常有降级标记或缺少正常 ack
echo "$RESP_FEIGN" | grep -qiE 'fallback|degraded|CIRCUIT' \
  && { echo "K2 FAIL: Feign 疑似走了 fallback，检查 DISPATCH_BASE_URL 与 dispatch Pod"; exit 1; } \
  || true

echo "-- async POST .../reports-async --"
DEVICE_ASYNC="k2-async-${TS}"
RESP_ASYNC="$(curl -sf -X POST \
  "http://127.0.0.1:${LOCAL_PORT}/api/v1/devices/${DEVICE_ASYNC}/reports-async" \
  -H "Content-Type: application/json" \
  -d "{\"payload\":{\"temp\":23,\"source\":\"k2-async\"}}")"
echo "$RESP_ASYNC"
echo "$RESP_ASYNC" | grep -q ACCEPTED

echo "-- wait consumer (5s) --"
sleep 5
kubectl logs -n "$NS" deploy/device-report-consumer --tail=30 | tee /tmp/k2-consumer-tail.txt
grep -qiE "${DEVICE_ASYNC}|Received kafka|batch" /tmp/k2-consumer-tail.txt \
  || echo "WARN: 日志未明显命中 deviceId；请到 PostgreSQL 查 device_report 表确认"

echo
echo "K2 PASS: sync + Feign + async 路径基本打通"