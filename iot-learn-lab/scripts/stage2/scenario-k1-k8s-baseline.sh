#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "${SCRIPT_DIR}/env.sh"

NS="${K8S_NAMESPACE}"
SVC="device-report-service"
LOCAL_PORT=8765

echo "== K1: device-report-service on minikube =="

kubectl get pods -n "$NS" -l app="$SVC"
kubectl rollout status deployment/"$SVC" -n "$NS" --timeout=120s

kubectl port-forward -n "$NS" "svc/${SVC}" "${LOCAL_PORT}:8765" &
PF_PID=$!
trap 'kill $PF_PID 2>/dev/null || true' EXIT
sleep 3

echo "-- health --"
curl -sf "http://127.0.0.1:${LOCAL_PORT}/actuator/health" | head -c 200
echo

echo "-- POST /api/v1/reports --"
DEVICE_ID="k8s-baseline-$(date +%s)"
curl -sf -X POST "http://127.0.0.1:${LOCAL_PORT}/api/v1/devices/${DEVICE_ID}/reports" \
  -H "Content-Type: application/json" \
  -d "{\"payload\":{\"temp\":25}}"

echo
echo "K1 PASS: Pod 健康且同步上报 201"