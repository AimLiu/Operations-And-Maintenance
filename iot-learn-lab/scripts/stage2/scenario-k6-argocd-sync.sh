#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "${SCRIPT_DIR}/env.sh"

APP="${ARGOCD_APP:-iot-learn-lab}"
NS_ARGO="${ARGOCD_NAMESPACE:-argocd}"
NS="${K8S_NAMESPACE}"
HOST="${INGRESS_HOST:-device-report.iot-learn.local}"

echo "== K6: Argo CD Application sync baseline =="

kubectl -n "$NS_ARGO" get deployment argocd-server >/dev/null
kubectl -n "$NS_ARGO" rollout status deployment/argocd-server --timeout=120s

if ! kubectl -n "$NS_ARGO" get application "$APP" >/dev/null 2>&1; then
  echo "K6 FAIL: Application ${APP} not found in ${NS_ARGO}"
  echo "Apply: kubectl apply -f iot-learn-lab/infra/argocd/application-iot-learn-lab.yaml"
  exit 1
fi

SYNC=$(kubectl -n "$NS_ARGO" get application "$APP" -o jsonpath='{.status.sync.status}')
HEALTH=$(kubectl -n "$NS_ARGO" get application "$APP" -o jsonpath='{.status.health.status}')
echo "Application ${APP}: sync=${SYNC} health=${HEALTH}"

[[ "$SYNC" == "Synced" ]] || { echo "K6 FAIL: expected Synced, got ${SYNC}. Sync the app in UI/CLI."; exit 1; }
[[ "$HEALTH" == "Healthy" ]] || { echo "K6 FAIL: expected Healthy, got ${HEALTH}"; exit 1; }

kubectl get deploy -n "$NS" device-report-service command-dispatch-service device-report-consumer
kubectl rollout status deployment/device-report-service -n "$NS" --timeout=120s

echo "-- Ingress health --"
code=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: ${HOST}" \
  "http://${MINIKUBE_IP}/actuator/health" || true)
echo "http=${code}"
[[ "$code" == "200" ]] || {
  echo "K6 WARN: Ingress health not 200 (got ${code}); trying port-forward fallback check is manual"
  echo "K6 FAIL: expected Ingress health 200"
  exit 1
}

echo
echo "K6 PASS: Argo CD Application Synced+Healthy; Ingress health OK"