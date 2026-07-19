#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "${SCRIPT_DIR}/env.sh"

ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CHART="${ROOT}/infra/helm/iot-learn-lab"
NS="${K8S_NAMESPACE}"
REL="${HELM_RELEASE:-iot-learn}"

echo "== K4: Helm baseline (install state + history) =="

helm status "$REL" -n "$NS"
helm history "$REL" -n "$NS" | head -20

kubectl get deploy,svc,ingress -n "$NS"

echo "-- template dry-run (lint values-v1) --"
helm template "$REL" "$CHART" \
  -n "$NS" \
  -f "${CHART}/values.yaml" \
  -f "${CHART}/values-v1.yaml" >/dev/null

echo "-- Ingress health --"
curl -sf -H "Host: ${INGRESS_HOST}" "http://${MINIKUBE_IP}/actuator/health" | head -c 200
echo

echo "-- NodePort metrics head --"
curl -sf "http://${MINIKUBE_IP}:${REPORT_NODE_PORT}/actuator/prometheus" | head -c 80
echo

echo
echo "K4 PASS: Helm release healthy; Ingress + NodePort reachable\n"