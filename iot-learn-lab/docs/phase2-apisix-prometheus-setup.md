# APISIX Prometheus 指标配置与排查指南

> **适用场景：** Phase 2 网关实验（G2–G6）中，Prometheus/Grafana 与 curl 观测结果不一致。  
> **环境：** APISIX 3.13（Docker `apisix-home-iot`）、Prometheus（Docker `prometheus-learn`）、Route `device-report-service`。

---

## 一、两步配置分别做什么？（核心原理）

APISIX 的 Prometheus 集成是 **两层结构**，缺一不可：

```
┌─────────────────────────────────────────────────────────────────┐
│  第一层：config.yaml → plugin_attr.prometheus（静态配置）         │
│  ─────────────────────────────────────────────────────────────  │
│  作用：定义「指标服务器」和「允许采集哪些类型的指标」              │
│  · 9091 端口是否监听（export_addr）                              │
│  · 是否启用 http_status / http_latency / bandwidth（metrics 段） │
│  类比：安装并启动监控探针，但还没指定监控哪条 API                  │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│  第二层：Route / Global Rule → prometheus 插件（运行时配置）      │
│  ─────────────────────────────────────────────────────────────  │
│  作用：告诉 APISIX「这条路由的流量要写入 Prometheus 指标」        │
│  · 在 device-report-service 路由上 PATCH prometheus 插件         │
│  · prefer_name: true → route label 用 name 而非数字 ID           │
│  类比：给具体 API 贴上「需要采集」的标签                          │
└─────────────────────────────────────────────────────────────────┘
                              ↓
                    请求经 :9080 进入路由
                              ↓
              prometheus 插件在 log 阶段写入指标
                              ↓
              :9091/apisix/prometheus/metrics 暴露
                              ↓
              Prometheus scrape → Grafana 展示
```

### 只做第一层、不做第二层时

`:9091` 能访问，但只有 **基础设施指标**：

| 有 | 无 |
|----|-----|
| `apisix_etcd_reachable` | `apisix_http_status` |
| `apisix_http_requests_total`（全局计数） | `apisix_http_latency` |
| `apisix_node_info` | `apisix_bandwidth` |
| `apisix_nginx_http_current_connections` | 按 route 的 QPS / 延迟 |

这就是排查初期 `grep apisix_http_status` 为空的原因。

### 只做第二层、不做第一层时

路由挂了 `prometheus` 插件，但 `config.yaml` 未启用 `metrics.http_status` 等，Per-route 指标同样不会出现（APISIX 3.8+ 常见，见 [apache/apisix#10921](https://github.com/apache/apisix/issues/10921)）。

---

## 二、本环境完整配置

### 2.1 config.yaml（`/work/Keycloak/config/apisix/config.yaml`）

```yaml
plugin_attr:
  prometheus:
    export_uri: /apisix/prometheus/metrics
    metric_prefix: apisix_
    enable_export_server: true
    export_addr:
      ip: 0.0.0.0          # Docker 内必须 0.0.0.0，否则 WSL IP 访问不到
      port: 9091
    metrics:
      http_status:
        expire: 0
      http_latency:
        expire: 0
      bandwidth:
        expire: 0
```

修改后重启 APISIX：

```bash
docker restart apisix-home-iot
```

### 2.2 路由挂载 prometheus 插件（第二步）

**含义：** 在 `device-report-service` 这条路由上，除了 `limit-count`，再启用 `prometheus` 插件，让该路由的 HTTP 流量被采集。

```bash
export ADMIN_API="${ADMIN_API:-http://localhost:9180}"
export ADMIN_KEY="${ADMIN_KEY:-edd1c9f034335f136f87ad84b625c8f1}"
export ROUTE_ID="00000000000000000160"

curl -s "${ADMIN_API}/apisix/admin/routes/${ROUTE_ID}" -X PATCH \
  -H "X-API-KEY: ${ADMIN_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "plugins": {
      "limit-count": {
        "count": 30,
        "time_window": 60,
        "rejected_code": 429,
        "key": "remote_addr",
        "key_type": "var",
        "policy": "local"
      },
      "prometheus": {
        "prefer_name": true
      }
    }
  }' | jq .
```

**PATCH 返回的 JSON 说明配置已生效：**

- `plugins.limit-count`：限流规则（30 次/60 秒）
- `plugins.prometheus.prefer_name: true`：Prometheus 的 `route` label 使用 `device-report-service` 而非 `00000000000000000160`
- `upstream` / `upstream_id`：转发到 Windows `192.168.16.1:8765` 不变

**替代方案：** Global Rule 对所有路由启用 prometheus（适合多路由统一采集）：

```bash
curl -s "${ADMIN_API}/apisix/admin/global_rules/1" -X PUT \
  -H "X-API-KEY: ${ADMIN_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"plugins":{"prometheus":{"prefer_name":true}}}' | jq .
```

---

## 三、验证清单

```bash
# 1. 打流量（会产生 201 和 429）
for i in $(seq 1 35); do
  curl -s -o /dev/null -w "%{http_code}\n" -X POST \
    "http://localhost:9080/api/v1/devices/verify-${i}/reports" \
    -H "Content-Type: application/json" \
    -d '{"payload":{"temperature":25}}'
done

# 2. 指标类型应包含 http_status / http_latency / bandwidth
curl -s http://192.168.19.64:9091/apisix/prometheus/metrics | \
  grep -E '^# TYPE apisix_' | awk '{print $3}' | sort -u

# 3. 应有上游 201（prefer_name 时 route=device-report-service）
curl -s http://192.168.19.64:9091/apisix/prometheus/metrics | \
  grep apisix_http_status | head -5
```

**修复前（仅基础设施指标）：**

```
apisix_etcd_modify_indexes
apisix_etcd_reachable
apisix_http_requests_total
apisix_nginx_http_current_connections
apisix_node_info
...
```

**修复后（新增流量指标）：**

```
apisix_bandwidth
apisix_http_latency
apisix_http_status
...
```

---

## 四、`apisix_http_status` 指标语义（必读）

### 4.1 核心结论：curl 看到的 ≠ `apisix_http_status` 记录的

APISIX 官方对 **`apisix_http_status`** 的定义：

> HTTP status codes **returned from upstream Services**（来自 **上游服务** 的状态码）

label **`code`** 的含义：

> HTTP response code **returned by the upstream node**（**上游节点** 返回的码）

因此，该指标回答的是 **「后端应用返回了什么？」**，而不是 **「客户端最终收到了什么？」**。

```
┌──────────────────────────────────────────────────────────────┐
│  客户端 ←── 最终状态码（201 / 429 / 504 …）←── $status       │
│            ↑                                                  │
│  APISIX 网关层（limit-count / limit-req / read timeout …）   │
│            ↑                                                  │
│  upstream（Spring Boot 返回 201 / 500 …）←── $upstream_status │
└──────────────────────────────────────────────────────────────┘

apisix_http_status{code="…"}  →  对齐 upstream 侧（$upstream_status）
                                 不对齐客户端最终 $status
```

### 4.2 三类响应的对照表（本环境实测）

| 场景 | curl 客户端 | 谁产生的 | `apisix_http_status` | 推荐观测方式 |
|------|------------|---------|---------------------|-------------|
| 正常上报经网关 | **201** | upstream | ✅ `code="201"` | `http_status` / 应用 QPS |
| limit-count / limit-req | **429** | 网关插件层 | ❌ 通常无 `code="429"` | curl 计数；入口 − 201 差值 |
| upstream read timeout（G5） | **504** | 网关超时 | ❌ 通常无 `code="504"` | **curl 504**；入口 − 201 差值 |
| 下游宕机（G6） | **502/504** | 网关等 upstream | ⚠️ 视版本/场景，常不完整 | curl + 差值 + 应用 `up` |

**重要：** curl 返回 504 **说明网关 timeout 已生效**；`:9091` 里 `grep apisix_http_status.*504` 为空 **不代表配置失败**，而是指标语义如此。

本环境验证命令（G5）：

```bash
curl -s -o /dev/null -w "%{http_code}\n" -X POST \
  "http://localhost:9080/api/v1/debug/slow-query?seconds=5"
# Expected: 504

curl -s http://192.168.19.64:9091/apisix/prometheus/metrics | grep -E '502|504' | grep apisix
# Expected: 常为空（网关 504 不进 http_status）
```

### 4.3 为什么网关「知道」504，却不写进 `apisix_http_status`？

网关 timeout 时的时序：

```
T=0s   客户端请求进入 APISIX，转发到 192.168.16.1:8765
T=0~3s upstream 仍在执行（如 pg_sleep 5s），尚未返回 HTTP 响应
T=3s   read timeout 到期，APISIX 主动断开，向客户端发送 504
       → 客户端 $status = 504
       → upstream 可能从未返回完整 HTTP 响应
       → apisix_http_status 无 upstream 504 可记录
```

与 Nginx/OpenResty 变量类比：

| 变量 | 含义 | 504 timeout 时 |
|------|------|---------------|
| `$upstream_status` | 从后端读到的状态 | 常为空或未完成 |
| `$status` | **最终** 返回客户端的状态 | **504** |

Prometheus 插件默认把 **`code` label 绑在 upstream 侧**，所以 **网关代发的 504 不会出现在 `apisix_http_status{code="504"}`**。

这是 **设计取舍**，不是 bug：

- **好处：** `http_status` 专用于判断 **Java 应用 / DB** 返回什么，与网关策略（限流、超时）解耦。
- **代价：** 不能用 `apisix_http_status{code=~"502|504"}` 单独观测网关超时；需用其他手段（见 4.5）。

社区类似讨论：limit-count 的 429 不进 metrics — [apache/apisix#11995](https://github.com/apache/apisix/issues/11995)。

### 4.4 limit-count 与 429

`limit-count` / `limit-req` 在 **插件层** 直接返回 429，请求 **未到达** upstream：

```
客户端 → APISIX → limit-count
                    ├─ 通过 → upstream → 201 → apisix_http_status{code="201"} ✅
                    └─ 拒绝 → 429（插件层）→ apisix_http_status{code="429"} ❌
```

429 可通过 **curl 状态码**、**G2/G3 脚本计数**、或 **差值 PromQL** 观测。

### 4.5 G5 上游超时与 504

G5 配置 upstream `read=3s` 后，slow-query 5s 经网关：

```bash
curl -X POST "http://localhost:9080/api/v1/debug/slow-query?seconds=5"
# HTTP 504  →  Task 9 成功
```

**不要依赖：**

```promql
# 在本环境常为空，不能作为 G5 通过标准
sum(rate(apisix_http_status{route="device-report-service",code=~"502|504"}[1m]))
```

**原因补充：** slow-query 路径为 `/api/v1/debug/*`，即使未来某版本记录了 504，`route` label 也可能是 **debug 路由**（如 `device-report-debug`），而非 `device-report-service`。

**G5 推荐观测：**

| 目标 | 方式 |
|------|------|
| 超时生效 | curl slow-query → **504** |
| 压测期网关行为 | 入口 `latency_count` vs 上游 **201** |
| Grafana Panel | 「Rejected」= **非 upstream 201 QPS（约）**，不是 504 计数 |
| 应用侧 | P99、`hikaricp_*`（pending > 0 非必须） |

### 4.6 Phase 2 推荐 PromQL（网关 vs 应用）

```promql
# 网关入口 QPS（含被插件拒绝、被 timeout 掐断的请求）
sum(rate(apisix_http_latency_count{type="request",route="device-report-service"}[1m]))

# 到达 Windows 后端的 QPS（仅 upstream 返回 201 的请求）
sum(rate(apisix_http_status{route="device-report-service",code="201"}[1m]))

# 未变成 upstream 201 的 QPS（含 429、504 等，无法按 code 拆分）
sum(rate(apisix_http_latency_count{type="request",route="device-report-service"}[1m]))
-
sum(rate(apisix_http_status{route="device-report-service",code="201"}[1m]))

# 应用侧实际处理 QPS（对照）
sum(rate(http_server_requests_seconds_count{
  application="device-report-service",
  uri="/api/v1/devices/{deviceId}/reports"
}[1m]))
```

G2 限流生效：**入口 QPS >> 应用 QPS**。  
G5 压测尖峰：**入口 QPS > 201 QPS**，差值含网关 timeout/排队，**不等于** limit 插件拦截。

### 4.7 若必须统计「客户端最终状态码」

| 方式 | 说明 |
|------|------|
| **脚本 / 黑盒探测** | 定期 curl slow-query，断言 HTTP 504（G5 已用） |
| **APISIX access log** | 日志中 `$status` 为最终码，可接 Loki/ELK 统计 504 |
| **差值 PromQL** | 4.6 第三节，近似「非 upstream 201」 |
| **extra_labels（进阶）** | `config.yaml` 中为 `http_status` 配置 `$status` 等（需查版本文档并实测） |

---

## 五、排查过程记录

### 5.1 Prometheus 指标未启用（2026-07-04）

| 步骤 | 现象 | 结论 |
|------|------|------|
| 跑 G2 脚本 | `429=2800`，限流正常 | 脚本与 limit-count 无问题 |
| Prometheus 查 `apisix_http_status{code="429"}` | 空 | 先怀疑 PromQL / 时间范围 |
| curl `:9091` grep 429 | 仅匹配 hostname 中的数字 | 非 HTTP 429 指标 |
| curl `:9091` grep `apisix_http_status` | 完全无输出 | APISIX 未导出 HTTP 流量指标 |
| `grep '^# TYPE apisix_'` | 仅 etcd/nginx/node 等 | 确认缺 http_status/latency/bandwidth |
| 改 config.yaml 启用 metrics + 重启 | — | 第一层完成 |
| PATCH 路由挂载 prometheus 插件 | 返回含 `plugins.prometheus` | 第二层完成 |
| 再次 grep TYPE + http_status | 有 201 等指标 | **修复成功** |

### 5.2 双限流插件叠加（2026-07-04）

| 步骤 | 现象 | 结论 |
|------|------|------|
| `jq '.value.plugins \| keys'` | limit-count + limit-req + prometheus | G2/G3 对比无效 |
| PATCH 时对旧插件传 `null` | 仅保留一个 limit + prometheus | 实验可对比 |

### 5.3 G5 与网关 504 不进 metrics（2026-07-05）

| 步骤 | 现象 | 结论 |
|------|------|------|
| G5 slow-query 经网关 | curl **504** | upstream read timeout 生效 ✅ |
| 40 次 device report | 全 **201** | 已关 limit 插件 ✅ |
| `grep apisix.*504` on `:9091` | **空** | 网关 504 不进 `apisix_http_status`（见第四节） |
| PromQL `http_status{code=~"502\|504"}` | Empty | 非配置错误，指标语义限制 |
| Grafana Rejected 尖峰 | 高，429 Rate=0 | 差值 = 非 upstream 201，含 timeout/高并发 |

**误区总结：**

1. G2 脚本没问题；Prometheus 空是 APISIX 指标未启用，不是抓取失败。
2. **`apisix_http_status` 只记录 upstream 状态码**；429（插件）、504（网关 timeout）常不在此指标中。
3. **curl 504 = G5 成功**；不要以 `http_status{code="504"}` 为空判定失败。
4. Grafana「Rejected QPS」应理解为 **「非 upstream 201 QPS（约）」**，不是 429/504 计数。
5. `:9091` 能访问 ≠ HTTP 流量指标已启用；需两层配置都完成。
6. `prefer_name: true` 后 PromQL 用 `route="device-report-service"`；slow-query 可能在 debug 路由。
7. **切换 limit-count ↔ limit-req 时必须对旧插件传 `null`**，否则两个限流插件同时生效。

---

## 六、面试话术速查

> **`apisix_http_status` 是 upstream 返回码，不是客户端最终状态码。** limit-count 的 429 在插件层产生，upstream read timeout 的 504 由网关产生，两者通常都不进 `http_status`。观测网关限流/超时应结合 curl、入口 `latency_count` 与 upstream 201 的差值、以及应用 QPS 对比。G5 我用 curl 验证 slow-query 经网关返回 504，证明 timeout 配置生效，而不依赖 PromQL 里的 504 序列。

---

## 七、参考

- APISIX prometheus 插件：https://apisix.apache.org/docs/apisix/plugins/prometheus/
- limit-count 拒绝与 metrics：https://github.com/apache/apisix/issues/11995
- 缺 metrics 配置：https://github.com/apache/apisix/issues/10921
- Phase 2 计划：`docs/superpowers/plans/2026-07-03-phase2-gateway-protection.md`
