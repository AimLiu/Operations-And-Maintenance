#!/usr/bin/env bash
# iot-learn-lab/infra/apisix/bootstrap-device-report-gateway.sh
set -euo pipefail

ADMIN_API="${ADMIN_API:-http://localhost:9180}"
ADMIN_KEY="${ADMIN_KEY:-edd1c9f034335f136f87ad84b625c8f1}"
ROUTE_ID="${ROUTE_ID:-00000000000000000160}"
PLUGIN="${1:-limit-count}"

case "$PLUGIN" in
  limit-count)
    PLUGIN_JSON='{"limit-count":{"count":30,"time_window":60,"rejected_code":429,"key":"remote_addr","key_type":"var","policy":"local"},"limit-req":null,"prometheus":{"prefer_name":true}}'
    ;;
  limit-req)
    PLUGIN_JSON='{"limit-req":{"rate":10,"burst":5,"rejected_code":429,"key":"remote_addr","key_type":"var"},"limit-count":null,"prometheus":{"prefer_name":true}}'
    ;;
  none)
    PLUGIN_JSON='{"limit-count":null,"limit-req":null,"prometheus":{"prefer_name":true}}'
    ;;
  *)
    echo "Usage: $0 [limit-count|limit-req|none]"; exit 1
    ;;
esac

curl -s "${ADMIN_API}/apisix/admin/routes/${ROUTE_ID}" -X PATCH \
  -H "X-API-KEY: ${ADMIN_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"plugins\": ${PLUGIN_JSON}}" | jq .