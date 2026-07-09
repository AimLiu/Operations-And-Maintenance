# PATCH upstream，两节点 90/10
curl -s "${ADMIN_API}/apisix/admin/upstreams/${UPSTREAM_ID}" -X PATCH \
  -H "X-API-KEY: ${ADMIN_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "nodes": {
      "192.168.16.1:8765": 100,
      "192.168.16.1:8766": 0
    },
    "timeout": { "connect": 3, "send": 3, "read": 10 }
  }' | jq .