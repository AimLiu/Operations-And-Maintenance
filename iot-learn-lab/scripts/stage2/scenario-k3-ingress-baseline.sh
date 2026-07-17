#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "${SCRIPT_DIR}/env.sh"

NS="${K8S_NAMESPACE}"
HOST="${INGRESS_HOST}"
TS="$(date +%s)"
SAMPLES="${K3_LATENCY_SAMPLES:-20}"

echo "== K3: Ingress baseline + Prometheus NodePort =="

if [[ -z "${MINIKUBE_IP:-}" ]]; then
  echo "K3 FAIL: minikube ip 为空，请先 minikube start"
  exit 1
fi

kubectl rollout status deployment/device-report-service -n "$NS" --timeout=120s
kubectl get ingress,svc -n "$NS"

echo "-- Ingress via Host header (health) --"
curl -sf -H "Host: ${HOST}" "http://${MINIKUBE_IP}/actuator/health" | head -c 300
echo

echo "-- Ingress sync POST --"
DEVICE_INGRESS="k3-ingress-${TS}"
curl -sf -H "Host: ${HOST}" -X POST \
  "http://${MINIKUBE_IP}/api/v1/devices/${DEVICE_INGRESS}/reports" \
  -H "Content-Type: application/json" \
  -d "{\"payload\":{\"temp\":31,\"source\":\"k3-ingress\"}}"
echo

echo "-- NodePort metrics scrape (raw) --"
curl -sf "http://${MINIKUBE_IP}:${REPORT_NODE_PORT}/actuator/prometheus" | head -c 120
echo
curl -sf "http://${MINIKUBE_IP}:${DISPATCH_NODE_PORT}/actuator/prometheus" | head -c 120
echo

# 延迟对照：Ingress vs IDEA（若可达）vs NodePort
latency_avg() {
  local url="$1"
  local extra_curl_args=("${@:2}")
  local sum=0
  local i
  for ((i=1; i<=SAMPLES; i++)); do
    local t
    t="$(curl -s -o /dev/null -w '%{time_total}' "${extra_curl_args[@]}" "$url" || echo 9.999)"
    sum="$(awk -v a="$sum" -v b="$t" 'BEGIN{printf "%.6f", a+b}')"
  done
  awk -v s="$sum" -v n="$SAMPLES" 'BEGIN{printf "%.4f", s/n}'
}

HEALTH_PATH="/actuator/health"
INGRESS_URL="http://${MINIKUBE_IP}${HEALTH_PATH}"
NODEPORT_URL="http://${MINIKUBE_IP}:${REPORT_NODE_PORT}${HEALTH_PATH}"
IDEA_URL="http://${WSL_TO_WINDOWS_IP}:8765${HEALTH_PATH}"

echo "-- latency avg over ${SAMPLES} samples (health GET) --"
INGRESS_AVG="$(latency_avg "$INGRESS_URL" -H "Host: ${HOST}")"
NODEPORT_AVG="$(latency_avg "$NODEPORT_URL")"
echo "ingress_host_header_avg_s=${INGRESS_AVG}"
echo "nodeport_avg_s=${NODEPORT_AVG}"

if curl -sf --connect-timeout 1 "$IDEA_URL" >/dev/null 2>&1; then
  IDEA_AVG="$(latency_avg "$IDEA_URL")"
  echo "idea_direct_avg_s=${IDEA_AVG}"
else
  echo "idea_direct_avg_s=SKIP (Windows :8765 不可达；仅对照 Ingress vs NodePort)"
fi

echo
echo "K3 PASS: Ingress + NodePort metrics 路径打通"