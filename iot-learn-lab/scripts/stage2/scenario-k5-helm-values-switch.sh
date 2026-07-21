#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "${SCRIPT_DIR}/env.sh"

ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CHART="${ROOT}/infra/helm/iot-learn-lab"
NS="${K8S_NAMESPACE}"
REL="${HELM_RELEASE:-iot-learn}"
HOST="${INGRESS_HOST}"

echo "== K5: Helm values switch (v1 → v2+canary → v1) =="

helm upgrade "$REL" "$CHART" -n "$NS" \
  -f "${CHART}/values.yaml" \
  -f "${CHART}/values-minikube.yaml" \
  -f "${CHART}/values-v2.yaml" \
  --wait --timeout 5m

echo "-- expect canary 5xx --"
FAILS=0
for i in 1 2 3 4 5; do
  code=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: ${HOST}" \
    -X POST "http://${MINIKUBE_IP}/api/v1/devices/k5-bug-${i}/reports" \
    -H "Content-Type: application/json" \
    -d "{\"payload\":{\"temp\":1,\"source\":\"k5\"}}" || true)
  echo "attempt=$i http=$code"
  [[ "$code" =~ ^5 ]] && FAILS=$((FAILS+1))
done
[[ "$FAILS" -ge 1 ]] || { echo "K5 FAIL: expected at least one 5xx under canary-bug"; exit 1; }

helm upgrade "$REL" "$CHART" -n "$NS" \
  -f "${CHART}/values.yaml" \
  -f "${CHART}/values-minikube.yaml" \
  -f "${CHART}/values-v1.yaml" \
  --wait --timeout 5m

curl -sf -H "Host: ${HOST}" \
  -X POST "http://${MINIKUBE_IP}/api/v1/devices/k5-ok-$(date +%s)/reports" \
  -H "Content-Type: application/json" \
  -d "{\"payload\":{\"temp\":2,\"source\":\"k5-ok\"}}"
echo

echo "K5 PASS: v2+canary produced 5xx; v1 restored"