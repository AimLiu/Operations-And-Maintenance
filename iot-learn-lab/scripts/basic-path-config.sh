# WSL 内访问 WSL Docker（APISIX）
export GATEWAY_URL="${GATEWAY_URL:-http://localhost:9080}"         # APISIX 网关
export ADMIN_API="${ADMIN_API:-http://localhost:9180}"             # APISIX Admin / Dashboard API

# WSL 内访问 Windows 上的 Spring Boot
export DIRECT_URL="${DIRECT_URL:-http://192.168.16.1:8765}"        # 直连应用（压测对比用）
export UPSTREAM="${UPSTREAM:-192.168.16.1:8765}"                   # APISIX upstream 节点（Admin API 配置用）

export ADMIN_KEY="${ADMIN_KEY:-edd1c9f034335f136f87ad84b625c8f1}"  # config.yaml 中的 admin key
export ROUTE_ID="${ROUTE_ID:-00000000000000000160}"
export UPSTREAM_ID="${UPSTREAM_ID:-00000000000000000158}"
export NACOS_ADDR="${NACOS_ADDR:-192.168.19.64:8848}"
export REDIS_HOST="${REDIS_HOST:-192.168.19.64}"
# 可选：Windows 浏览器访问 WSL 服务时覆盖（一般脚本不需要）
# export GATEWAY_URL=http://192.168.19.64:9080
# export ADMIN_API=http://192.168.19.64:9180

# phase4
export GATEWAY_URL="${GATEWAY_URL:-http://localhost:9080}"
export DIRECT_V1="${DIRECT_V1:-http://192.168.16.1:8765}"
export DIRECT_V2="${DIRECT_V2:-http://192.168.16.1:8766}"
export NACOS_ADDR="${NACOS_ADDR:-192.168.19.64:8848}"