# Phase 2 网关层防护 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 APISIX 网关上配置限流（`limit-count` / `limit-req`）、上游超时与熔断（`api-breaker`），通过 WSL 压测脚本与 Grafana 对比「网关 QPS vs 应用 QPS」，完成 Phase 2 全部可复现学习场景。

**Architecture:** 流量从 WSL 压测脚本进入 APISIX（WSL Docker `:9080`），经 upstream 转发至 **Windows** 上 `device-report-service`（`192.168.16.1:8765`）；限流/熔断在网关层生效。Prometheus（WSL Docker）抓取：APISIX 用 **WSL IP** `192.168.19.64:9091`，应用用 **Windows 网关 IP** `192.168.16.1:8765`。Grafana 新增 Gateway 行对比入口与后端 QPS。

**Tech Stack:** APISIX 3.13, etcd, Prometheus 2.55, Grafana 11.3, Java 21 / Spring Boot 3.3（device-report-service）, PostgreSQL 16, wrk/ab（WSL 压测）

**Spec 来源:** `docs/superpowers/specs/2026-07-02-ops-learning-plan-design.md`（Phase 2 / W3–W4）

**前置条件（Phase 1 已完成）:**

- [x] `device-report-service` 运行在 **Windows** `:8765`（IDEA 启动）
- [x] APISIX 运行在 **WSL Docker**，upstream 指向 `192.168.16.1:8765`（priority=100，无 OIDC）
- [x] APISIX 路由 **Route ID** = `00000000000000000160`，**name** = `device-report-service`（Dashboard 创建，见下文）
- [x] Prometheus Target：`device-report-service`（`192.168.16.1:8765`）UP、`apisix`（`192.168.19.64:9091`）UP
- [x] APISIX Prometheus **两层配置**已完成（`config.yaml` metrics + 路由 `prometheus` 插件，见 [`iot-learn-lab/docs/phase2-apisix-prometheus-setup.md`](../../../iot-learn-lab/docs/phase2-apisix-prometheus-setup.md)）
- [x] Grafana Dashboard `device-report-observability` 已有应用层 4 行 Panel

**时间预算:** 2 周 × 10–15h = 20–30h

---

## WSL2 + Windows 网络拓扑（必读）

本实验环境为 **Windows 11 + WSL2 + Docker Desktop**，存在两个不同方向的 IP，**不可混用**。

### 两个 IP 的含义

| IP | 归属 | 典型用途 |
|----|------|---------|
| **`192.168.19.64`** | WSL2 虚拟机 `eth0`（`ifconfig` 可见） | Windows 访问 WSL 内服务；WSL 内访问本机 Docker 映射端口 |
| **`192.168.16.1`** | WSL 访问 Windows 宿主机的网关 | WSL / WSL Docker 访问 Windows 上跑的应用 |

### 访问方向对照表

| 调用方 | 目标 | 正确地址 | 错误示例 |
|--------|------|---------|---------|
| **WSL 终端** 压测脚本 → APISIX 网关 | WSL Docker | `http://localhost:9080` 或 `http://192.168.19.64:9080` | ~~`192.168.16.1:9080`~~（Windows 上无此端口） |
| **WSL 终端** → Admin API / Dashboard | WSL Docker | `http://localhost:9180` 或 `http://192.168.19.64:9180` | ~~`192.168.16.1:9180`~~ |
| **Windows 浏览器** → APISIX Dashboard | WSL Docker | `http://192.168.19.64:9180/ui/routes` | — |
| **WSL 终端** 压测 → 直连应用 | Windows IDEA | `http://192.168.16.1:8765` | ~~`localhost:8765`~~（WSL 内 localhost 不是 Windows） |
| **APISIX 容器** upstream → 应用 | Windows | `192.168.16.1:8765` | ~~`localhost:8765`~~ |
| **Prometheus 容器** scrape 应用 | Windows | `192.168.16.1:8765` | — |
| **Prometheus 容器** scrape APISIX | WSL Docker | `192.168.19.64:9091`（`metrics_path: /apisix/prometheus/metrics`） | ~~`apisix-home-iot:9091`~~（跨 compose 网络 DNS 失败） |
| **Windows 浏览器** → Grafana / Prometheus | WSL Docker | `http://192.168.19.64:3000` / `:9090` | — |
| **WSL 终端** → Grafana / Prometheus | 本机 Docker | `http://localhost:3000` / `:9090` | — |

### 架构图（含 IP）

```
┌─────────────────────────────────────────────────────────────────┐
│  Windows 11                                                      │
│  device-report-service :8765  ←── 192.168.16.1 ──┐              │
│  浏览器 → 192.168.19.64:9180 / :9080 / :3000      │              │
└──────────────────────────────────────────────────│──────────────┘
                                                   │
┌──────────────────────────────────────────────────│──────────────┐
│  WSL2  (eth0: 192.168.19.64)                     │              │
│                                                  ↓              │
│  压测脚本 ──→ localhost:9080 ──→ APISIX (Docker)              │
│                    │              upstream: 192.168.16.1:8765  │
│                    │              :9091 metrics                  │
│  Prometheus ──→ 192.168.19.64:9091 (apisix job)                │
│            └──→ 192.168.16.1:8765  (device-report job)          │
│  Grafana :3000                                                 │
└─────────────────────────────────────────────────────────────────┘
```

> **记忆口诀：**  
> - **找 Windows 上的 Java** → `192.168.16.1`  
> - **找 WSL 里的 Docker** → `localhost` 或 `192.168.19.64`  
> - **APISIX upstream 永远指向 Windows 应用** → `192.168.16.1:8765`

---

## 文件结构

```
Operations-And-Maintenance/
├── iot-learn-lab/
│   ├── infra/
│   │   ├── apisix/
│   │   │   ├── routes/
│   │   │   │   └── device-report-route.json          # 路由 + 插件 JSON 模板
│   │   │   ├── bootstrap-device-report-gateway.sh    # Admin API 一键配置
│   │   │   └── plugin-config/
│   │   │       ├── limit-count.json
│   │   │       ├── limit-req.json
│   │   │       └── api-breaker.json
│   │   ├── prometheus/
│   │   │   └── alert-rules-gateway.yml               # 429 / 502 告警（W4）
│   │   └── grafana/dashboards/
│   │       └── device-report-observability.json      # 追加 Gateway 行
│   ├── scripts/
│   │   ├── scenario-g1-gateway-baseline.sh           # 经网关基准压测
│   │   ├── scenario-g2-limit-count.sh                # 触发 429（固定窗口）
│   │   ├── scenario-g3-limit-req.sh                  # 触发 429（漏桶）
│   │   ├── scenario-g5-upstream-timeout.sh           # 慢上游 + 超时
│   │   └── scenario-g6-downstream-down.sh            # 下游宕机
│   └── docs/
│       ├── phase2-interview-notes.md                 # W3/W4 复盘（Task 12 产出）
│       └── phase2-apisix-prometheus-setup.md         # APISIX 指标两层配置 + 排查记录
└── docs/superpowers/plans/
    └── 2026-07-03-phase2-gateway-protection.md       # 本文件
```

**环境变量约定（WSL 脚本统一使用）:**

> 详见上文 **WSL2 + Windows 网络拓扑**：网关/Admin 在 WSL Docker，默认用 `localhost`；应用在 Windows，用 `192.168.16.1`。

```bash
# WSL 内访问 WSL Docker（APISIX）
export GATEWAY_URL="${GATEWAY_URL:-http://localhost:9080}"         # APISIX 网关
export ADMIN_API="${ADMIN_API:-http://localhost:9180}"             # APISIX Admin / Dashboard API

# WSL 内访问 Windows 上的 Spring Boot
export DIRECT_URL="${DIRECT_URL:-http://192.168.16.1:8765}"        # 直连应用（压测对比用）
export UPSTREAM="${UPSTREAM:-192.168.16.1:8765}"                   # APISIX upstream 节点（Admin API 配置用）

export ADMIN_KEY="${ADMIN_KEY:-edd1c9f034335f136f87ad84b625c8f1}"  # config.yaml 中的 admin key

# APISIX 路由 / Upstream 实体 ID（Dashboard 创建时为数字 ID，非 name）
export ROUTE_ID="${ROUTE_ID:-00000000000000000160}"               # Admin API: /routes/{ROUTE_ID}
export UPSTREAM_ID="${UPSTREAM_ID:-00000000000000000158}"        # Admin API: /upstreams/{UPSTREAM_ID}（改 timeout 用）

# 可选：Windows 浏览器访问 WSL 服务时覆盖（一般脚本不需要）
# export GATEWAY_URL=http://192.168.19.64:9080
# export ADMIN_API=http://192.168.19.64:9180
```

---

## APISIX Route ID 与 name（必读）

通过 **Dashboard** 创建的路由，Admin API 使用的 **Route ID** 通常是自动生成的数字串（如 `00000000000000000160`），**不等于**路由的 `name` 字段（如 `device-report-service`）。

| 概念 | 本环境取值 | 用途 |
|------|-----------|------|
| **Route ID** | `00000000000000000160` | Admin API：`/apisix/admin/routes/{ROUTE_ID}` |
| **Route name** | `device-report-service` | Dashboard 列表显示；Prometheus `route` label |
| **Upstream ID** | `00000000000000000158` | Admin API：`/apisix/admin/upstreams/{UPSTREAM_ID}` |
| **Upstream name** | `device-report-upstream` | Dashboard → Upstreams 页 |

> **常见误区：** 用 `device-report` 或 `name` 去查 Admin API 会得到 `"value": null`——路由存在，只是 **ID 不对**。

**查本环境 Route ID（换机器或重建路由后执行一次）：**

```bash
curl -s "${ADMIN_API}/apisix/admin/routes" \
  -H "X-API-KEY: ${ADMIN_KEY}" | \
  jq '.list[] | select(.value.name=="device-report-service") | {
    route_id: (.key | split("/") | last),
    name: .value.name,
    uri: .value.uri,
    upstream_name: .value.upstream.name,
    upstream_service: .value.upstream.service_name
  }'
```

Expected：`route_id` 为 `00000000000000000160`，`uri` 为 `/api/v1/devices/*/reports`。

**Admin API 修改原则（本环境）：**

| 改什么 | 方法 | 路径 |
|--------|------|------|
| 限流 / 熔断插件 | **PATCH** | `/routes/${ROUTE_ID}`，只传 `plugins`；**切换限流插件时对旧插件传 `null`** |
| upstream timeout | **PATCH** | `/upstreams/${UPSTREAM_ID}`，只传 `timeout` |
| 新建 debug 路由 | **PUT** | `/routes/device-report-debug`（自定义 ID，可选） |

> 对已存在的 Dashboard 路由，**不要用 PUT 整段覆盖 route**，否则会丢失 `service_name` 绑定的 Upstream 实体。  
> **切换 limit-count ↔ limit-req 时**：APISIX PATCH 会合并 plugins，必须对不再使用的插件设 `"limit-count": null` 或 `"limit-req": null`，否则两个限流插件同时生效。

---

## APISIX Prometheus 两层配置（必读）

Prometheus 能 scrape `:9091` **不等于** 已有网关 HTTP 流量指标。APISIX 3.13 需 **两层都配置**：

| 层 | 配置位置 | 作用 |
|----|---------|------|
| **第一层** | `config.yaml` → `plugin_attr.prometheus.metrics` | 启用指标类型（`http_status` / `http_latency` / `bandwidth`）+ 9091 监听 |
| **第二层** | Route 或 Global Rule → `prometheus` 插件 | 指定哪条路由的流量写入上述指标 |

只做第一层 → 仅有 `apisix_etcd_*`、`apisix_node_info` 等基础设施指标，**无** `apisix_http_status`。  
只做第二层 → Per-route 指标仍可能缺失（3.8+ 默认不采集 http_status）。

**本环境路由插件（第二层示例）：**

```json
"plugins": {
  "limit-count": { "count": 30, "time_window": 60, "rejected_code": 429, ... },
  "prometheus": { "prefer_name": true }
}
```

`prefer_name: true` → PromQL 中 `route="device-report-service"`（否则为 Route ID）。

**limit-count 与 429 指标：** `apisix_http_status` 只记录 **upstream 返回** 的状态码；插件层 429、网关 timeout 504 **通常不在** `code="429"` / `code="504"` 中。观测限流/超时请用「入口 QPS − 上游 201 QPS」或 curl。详见 **`iot-learn-lab/docs/phase2-apisix-prometheus-setup.md` 第四节**。

---

## 实验架构

```
压测脚本 (WSL 终端)
    ↓  localhost:9080 或 192.168.19.64:9080
APISIX (WSL Docker) :9080  ← limit-count / limit-req / api-breaker
    ↓  upstream → 192.168.16.1:8765
device-report-service (Windows IDEA) :8765
    ↓
PostgreSQL (WSL Docker, postgres-alpine :5432)
    ↓
Prometheus (WSL Docker) 抓取:
  - apisix → 192.168.19.64:9091  (/apisix/prometheus/metrics)
  - device-report-service → 192.168.16.1:8765 (/actuator/prometheus)
    ↓
Grafana (WSL Docker :3000) 对比: 网关 QPS vs 应用 QPS
```

---

## Phase 2 监控指标速查表

### 网关 vs 应用 对比（核心）

| 观察点 | 网关 PromQL | 应用 PromQL | 限流生效时的关系 |
|--------|------------|------------|-----------------|
| 入口 QPS（含 429） | `sum(rate(apisix_http_latency_count{type="request",route="device-report-service"}[1m]))` | — | 压测发出量 |
| 到达后端 QPS | `sum(rate(apisix_http_status{route="device-report-service",code="201"}[1m]))` | `sum(rate(http_server_requests_seconds_count{application="device-report-service",uri="/api/v1/devices/{deviceId}/reports"}[1m]))` | **应 ≤ 限流阈值** |
| 被网关拦截 QPS | 入口 QPS − 上游 201 QPS（见上两行相减） | — | limit-count 生效时 > 0 |
| 502/504 网关错误 | `sum(rate(apisix_http_status{route="device-report-service",code=~"502|504"}[1m]))` | — | 下游宕机/超时时上升 |
| 网关 P99 | `histogram_quantile(0.99, sum(rate(apisix_http_latency_bucket{type="request",route="device-report-service"}[5m])) by (le))` | 应用 P99 对照 | 超时/慢上游时升高 |

> **注意：** 不要用 `apisix_http_status{code="429"}` 或 `{code=~"502|504"}` 观测 limit/timeout——429、504 多为网关/插件产生，不进 upstream 指标。`route` label 在 `prefer_name: true` 时为 `device-report-service`。指标语义与排查见 **`iot-learn-lab/docs/phase2-apisix-prometheus-setup.md` §4**。

### 限流插件行为对照

| 插件 | 算法 | 典型参数 | 超限响应 |
|------|------|---------|---------|
| **limit-count** | 固定窗口计数 | `count=100, time_window=60` | 429，窗口内最多 100 次 |
| **limit-req** | 漏桶（请求速率） | `rate=50, burst=20` | 429，平均 50 req/s，允许突发 20 |
| **api-breaker** | 熔断器 | `break_response_code=503, unhealthy.http_statuses=[500,502,503,504]` | 503，下游连续失败后打开 |

### 面试考点速查

| 问题 | 要点 |
|------|------|
| 令牌桶 vs 漏桶 | 令牌桶允许一定突发；漏桶平滑输出速率。APISIX `limit-req`≈漏桶，`limit-count`≈固定窗口 |
| 限流放网关还是应用？ | 网关：统一入口、保护全链路；应用（Sentinel）：细粒度资源、业务级。理想：**网关粗限流 + 应用精限流** |
| 熔断 vs 降级 | 熔断：下游故障时快速失败；降级：返回兜底数据。APISIX `api-breaker` 是熔断，不是降级 |
| 为什么要有超时？ | 防止慢请求占满连接/线程，引发级联故障 |

---

## 学习场景编排（Phase 2 核心）

### 场景 G1：网关基准线（W3 Day 1）

**业务背景：** Phase 2 开始前，确认「经网关」与「直连」流量在监控上可对比。

**操作：**

```bash
# 直连 30s
DURATION=30 BASE_URL="$DIRECT_URL" ./iot-learn-lab/scripts/scenario-s2-device-burst.sh

# 经网关 30s
DURATION=30 BASE_URL="$GATEWAY_URL" ./iot-learn-lab/scripts/scenario-g1-gateway-baseline.sh
```

**关键指标：**

```promql
# 网关总 QPS
sum(rate(apisix_http_status{code="200"}[1m]))

# 应用 QPS
sum(rate(http_server_requests_seconds_count{application="device-report-service"}[1m]))
```

**预期：** 无限流插件时，两者 QPS 接近（网关略低因代理开销）。

**面试话术：** 「先建立 baseline，后续限流实验才能量化『被网关拦了多少』。」

---

### 场景 G2：limit-count 固定窗口限流（W3 Day 2–3）

**业务背景：** IoT 平台对每个租户/device 设每日/每分钟上报上限，超出返回 429。

**插件配置（Admin API）：**

```json
"limit-count": {
  "count": 30,
  "time_window": 60,
  "rejected_code": 429,
  "key": "remote_addr",
  "key_type": "var"
}
```

**操作：** 运行 `scenario-g2-limit-count.sh`（60s 内 >30 次请求）。

**预期曲线：**

1. 网关入口 `apisix_http_latency_count{type="request"}` 上升
2. 上游 `apisix_http_status{code="201"}` 与应用 QPS 被压制在约 **30/min ≈ 0.5/s**
3. **入口 QPS − 上游 201 QPS** 差值上升（被 limit-count 拦截量）
4. 应用 P99 仍正常（未被压垮）

**验证命令：**

```bash
curl -s -o /dev/null -w "%{http_code}\n" -X POST \
  "$GATEWAY_URL/api/v1/devices/device-001/reports" \
  -H "Content-Type: application/json" \
  -d '{"payload":{"temperature":25}}'
# 前 30 次 201/200，之后 429
```

---

### 场景 G3：limit-req 漏桶限流（W3 Day 4–5）

**业务背景：** 平滑设备上报峰值，平均 10 req/s，允许短时突发 5。

**插件配置：**

```json
"limit-req": {
  "rate": 10,
  "burst": 5,
  "rejected_code": 429,
  "key": "remote_addr",
  "key_type": "var"
}
```

**操作：** `wrk` 或 `scenario-g3-limit-req.sh` 以 50 req/s 压测 60s。

**预期：**

- 大量 429
- 应用 QPS 稳定在 ~10 左右
- 对比 G2：limit-req 关注**速率**，limit-count 关注**窗口总量**

---

### 场景 G4：Grafana 网关 Panel（W3 Day 5）

**业务背景：** 运维需要一张图同时看「入口流量 / 被拒绝 / 后端实际处理量」。

**新增 Panel 行 — Gateway：**

| Panel | 类型 | PromQL |
|-------|------|--------|
| Gateway Ingress QPS | Time series | `sum(rate(apisix_http_latency_count{type="request",route="device-report-service"}[1m]))` |
| Upstream 201 QPS | Time series | `sum(rate(apisix_http_status{route="device-report-service",code="201"}[1m]))` |
| Gateway vs App QPS | Time series | 入口 latency_count + 应用 http_server_requests 两条 |
| Rejected QPS (approx) | Time series | 入口 − 上游 201（两条相减） |
| Gateway P99 | Time series | `histogram_quantile(0.99, sum(rate(apisix_http_latency_bucket{type="request",route="device-report-service"}[5m])) by (le))` |

---

### 场景 G5：上游超时 + 慢查询（W4 Day 1–2）

**业务背景：** 下游 DB 慢查询导致响应超过网关超时，连接堆积。

**Upstream 实体 timeout 配置（本环境 Upstream ID = `00000000000000000158`）：**

```json
"timeout": {
  "connect": 3,
  "send": 5,
  "read": 3
}
```

**操作：**

1. PATCH Upstream 实体 `${UPSTREAM_ID}`，设置 `read=3s`（见 Task 9）
2. 触发慢查询：`POST /api/v1/debug/slow-query?seconds=5`（经网关；若无 debug 路由先按 Task 9 Step 2 创建）
3. 运行 `scenario-g5-upstream-timeout.sh`

**预期：**

- 经网关：504 Gateway Timeout 或 502（视 APISIX 版本）；**以 curl 验证为准**
- **`apisix_http_status{code=~"502|504"}` 常为空**（网关 504 不进 upstream 指标，见 prometheus 指南 §4.5）
- 应用 P99 可能升高；HikariCP pending 可能 > 0（与 Phase 1 S4 联动，非必须）
- Grafana「Rejected QPS」= 非 upstream 201 差值，**不是** 504 计数
- **网关超时保护：** 客户端不会无限等待

**面试话术：** 「超时是熔断的前置条件；没有超时，慢请求会占满网关到后端的连接。」

---

### 场景 G6：下游宕机 + api-breaker 熔断（W4 Day 3–4）

**业务背景：** Windows 上停止 `device-report-service`，网关应快速失败而非长时间挂起。

**步骤 A — 无熔断（观察坏现象）：**

1. 路由**不**启用 `api-breaker`
2. 停止 device-report-service
3. 压测经网关 → 观察 502/504 延迟很高

**步骤 B — 启用 api-breaker：**

```json
"api-breaker": {
  "break_response_code": 503,
  "break_response_body": "{\"error\":\"service unavailable, circuit open\"}",
  "break_response_headers": [
    {"key": "Content-Type", "value": "application/json"}
  ],
  "max_breaker_sec": 30,
  "unhealthy": {
    "http_statuses": [500, 502, 503, 504],
    "failures": 3
  },
  "healthy": {
    "http_statuses": [200, 201],
    "successes": 2
  }
}
```

**操作：** `scenario-g6-downstream-down.sh`

**预期：**

- 前几次 502/504
- 连续失败后路由返回 **503**（熔断打开）
- 恢复服务后，熔断器 half-open → 关闭

---

### 场景 G7：Phase 2 综合演练（W4 Day 5）

**操作顺序：**

1. G1 baseline（无限流）
2. 启用 limit-req → G3 压测 → 截图 429
3. 关闭 limit-req，启用 timeout → G5 慢查询
4. G6 下游宕机 + api-breaker
5. 填写 `phase2-interview-notes.md`

---

## W3 / W4 日程建议

| 天 | 场景 | 任务 | 时长 |
|----|------|------|------|
| D1 | G1 基准线 | Task 1–2 | 3h |
| D2 | G2 limit-count 理论 + 配置 | Task 3–4 | 3h |
| D3 | G2 压测 + 验证 429 | Task 5 | 3h |
| D4 | G3 limit-req | Task 6–7 | 4h |
| D5 | G4 Grafana Gateway 行 | Task 8 | 3h |
| D6 | 复盘 W3 + 面试题 | Task 12（部分） | 2h |
| D7 | G5 上游超时 | Task 9 | 4h |
| D8 | G5 + Phase1 S4 联动 | Task 10 | 3h |
| D9 | G6 api-breaker | Task 11 | 4h |
| D10 | G7 综合演练 | Task 12 | 3h |

---

## Implementation Tasks

### Task 1: APISIX 路由基线确认

**Files:**
- Verify: APISIX Dashboard 或 Admin API
- Reference: `/work/Keycloak/config/apisix/config.yaml`

- [ ] **Step 0: 确认环境变量（含 ROUTE_ID）**

```bash
echo "ADMIN_API=$ADMIN_API ROUTE_ID=$ROUTE_ID UPSTREAM_ID=$UPSTREAM_ID"
# Expected: ADMIN_API=http://localhost:9180
#           ROUTE_ID=00000000000000000160
#           UPSTREAM_ID=00000000000000000158
```

- [ ] **Step 1: 确认 device-report-service 路由存在且 priority=100**

```bash
curl -s "${ADMIN_API}/apisix/admin/routes/${ROUTE_ID}" \
  -H "X-API-KEY: ${ADMIN_KEY}" | jq '.value | {name, uri, priority, upstream, plugins}'
```

Expected: `name` 为 `device-report-service`，`priority` 为 `100`，`uri` 含 `/api/v1/devices/*/reports`，upstream 指向 `192.168.16.1:8765`，**无** openid-connect 插件。若字段全为 `null`，执行上文「查 Route ID」命令更新 `ROUTE_ID`。

- [ ] **Step 2: 确认经网关上报成功**

```bash
curl -s -X POST "${GATEWAY_URL}/api/v1/devices/device-via-apisix/reports" \
  -H "Content-Type: application/json" \
  -d '{"payload":{"temperature":30}}' | jq .
```

Expected: HTTP 201，JSON 含 `deviceId`.

- [ ] **Step 3: 确认 Prometheus 双 Target UP**

打开 `http://localhost:9090/targets`（WSL）或 `http://192.168.19.64:9090/targets`（Windows 浏览器），确认：
- `device-report-service` → `192.168.16.1:8765` **UP**
- `apisix` → `192.168.19.64:9091` **UP**

---

### Task 2: 创建网关压测脚本 G1

**Files:**
- Create: `iot-learn-lab/scripts/scenario-g1-gateway-baseline.sh`

- [ ] **Step 1: 编写脚本**

```bash
#!/usr/bin/env bash
# iot-learn-lab/scripts/scenario-g1-gateway-baseline.sh
# 场景 G1：经 APISIX 网关压测（复用 S2 逻辑，默认 GATEWAY_URL）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export BASE_URL="${GATEWAY_URL:-http://localhost:9080}"
export DURATION="${DURATION:-60}"

echo "=== G1 网关基准压测 ==="
echo "网关: $BASE_URL"
"$SCRIPT_DIR/scenario-s2-device-burst.sh"
echo "=== G1 完成：对比 Grafana 网关 QPS vs 应用 QPS ==="
```

- [ ] **Step 2: 赋予权限并运行**

```bash
chmod +x iot-learn-lab/scripts/scenario-g1-gateway-baseline.sh
GATEWAY_URL=http://localhost:9080 DURATION=30 \
  ./iot-learn-lab/scripts/scenario-g1-gateway-baseline.sh
```

Expected: 脚本无报错；Grafana 应用 QPS 有数据。

- [ ] **Step 3: Commit**

```bash
git add iot-learn-lab/scripts/scenario-g1-gateway-baseline.sh
git commit -m "feat(phase2): add G1 gateway baseline load test script"
```

---

### Task 3: limit-count 插件配置模板

**Files:**
- Create: `iot-learn-lab/infra/apisix/plugin-config/limit-count.json`
- Create: `iot-learn-lab/infra/apisix/bootstrap-device-report-gateway.sh`

- [ ] **Step 1: 创建插件 JSON 片段**

```json
{
  "limit-count": {
    "count": 30,
    "time_window": 60,
    "rejected_code": 429,
    "rejected_msg": "rate limit exceeded (limit-count)",
    "key": "remote_addr",
    "key_type": "var",
    "policy": "local"
  }
}
```

- [ ] **Step 2: 编写 bootstrap 脚本（PATCH 插件，保留现有 Upstream 绑定）**

```bash
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
```

- [ ] **Step 3: 赋予权限**

```bash
chmod +x iot-learn-lab/infra/apisix/bootstrap-device-report-gateway.sh
```

- [ ] **Step 4: Commit**

```bash
git add iot-learn-lab/infra/apisix/
git commit -m "feat(phase2): add APISIX gateway bootstrap and limit-count config"
```

---

### Task 4: Dashboard 启用 limit-count

- [ ] **Step 1: 应用 limit-count 插件**

```bash
./iot-learn-lab/infra/apisix/bootstrap-device-report-gateway.sh limit-count
```

- [ ] **Step 2: Dashboard 验证插件已挂载**

APISIX Dashboard → Routes → `device-report-service` → Plugins → 应看到 `limit-count`。

- [ ] **Step 3: 手动快速验证 429**

```bash
for i in $(seq 1 35); do
  code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    "${GATEWAY_URL}/api/v1/devices/d-${i}/reports" \
    -H "Content-Type: application/json" \
    -d '{"payload":{"temperature":25}}')
  echo "request $i: $code"
done
```

Expected: 前 ~30 个 201，之后出现 429。

---

### Task 5: G2 压测脚本

**Files:**
- Create: `iot-learn-lab/scripts/scenario-g2-limit-count.sh`

- [ ] **Step 1: 编写脚本**

```bash
#!/usr/bin/env bash
# iot-learn-lab/scripts/scenario-g2-limit-count.sh
set -euo pipefail

GATEWAY_URL="${GATEWAY_URL:-http://localhost:9080}"
DURATION="${DURATION:-90}"

echo "=== G2 limit-count 限流实验 ==="
echo "网关: $GATEWAY_URL, 持续: ${DURATION}s"
echo "预期: 429 数量上升，应用 QPS 被压制"

end=$((SECONDS + DURATION))
total=0
count_429=0
count_ok=0

while [ $SECONDS -lt $end ]; do
  for i in $(seq 1 20); do
    code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
      "$GATEWAY_URL/api/v1/devices/g2-${i}/reports" \
      -H "Content-Type: application/json" \
      -d "{\"payload\":{\"temperature\":$((20 + RANDOM % 10)),\"seq\":$SECONDS}}")
    total=$((total + 1))
    if [ "$code" = "429" ]; then count_429=$((count_429 + 1)); else count_ok=$((count_ok + 1)); fi
  done
  sleep 0.5
done

echo "=== 结果: total=$total ok=$count_ok 429=$count_429 ==="
echo "Grafana：对比 apisix_http_latency_count{type=\"request\"} vs 应用 QPS（429 不进 apisix_http_status）"
```

- [ ] **Step 2: 运行前确保 limit-count 已启用（Task 4）**

```bash
chmod +x iot-learn-lab/scripts/scenario-g2-limit-count.sh
./iot-learn-lab/infra/apisix/bootstrap-device-report-gateway.sh limit-count
./iot-learn-lab/scripts/scenario-g2-limit-count.sh
```

Expected: `429` 计数 > 0。

- [ ] **Step 3: Prometheus 验证（入口 vs 上游）**

```promql
sum(rate(apisix_http_latency_count{type="request",route="device-report-service"}[1m]))
sum(rate(apisix_http_status{route="device-report-service",code="201"}[1m]))
```

Expected：第一行 > 第二行（差值为被 limit-count 拦截量）。不要用 `code="429"`。

- [ ] **Step 4: Commit**

```bash
git add iot-learn-lab/scripts/scenario-g2-limit-count.sh
git commit -m "feat(phase2): add G2 limit-count load test script"
```

---

### Task 6: 切换 limit-req 插件

- [ ] **Step 1: 应用 limit-req**

```bash
./iot-learn-lab/infra/apisix/bootstrap-device-report-gateway.sh limit-req
```

- [ ] **Step 2: 确认 limit-count 已被替换**

Dashboard → Routes → Plugins：仅 `limit-req` + `prometheus`，**无** `limit-count`。

```bash
curl -s "${ADMIN_API}/apisix/admin/routes/${ROUTE_ID}" \
  -H "X-API-KEY: ${ADMIN_KEY}" | jq '.value.plugins | keys'
# Expected: ["limit-req", "prometheus"]
```

> PATCH 只传 `limit-req` **不会**自动删除 `limit-count`，必须显式 `"limit-count": null`（bootstrap 脚本已处理）。

---

### Task 7: G3 压测脚本（wrk 可选）

**Files:**
- Create: `iot-learn-lab/scripts/scenario-g3-limit-req.sh`

- [ ] **Step 1: 编写 curl 版压测脚本**

```bash
#!/usr/bin/env bash
# iot-learn-lab/scripts/scenario-g3-limit-req.sh
set -euo pipefail

GATEWAY_URL="${GATEWAY_URL:-http://localhost:9080}"
DURATION="${DURATION:-60}"

echo "=== G3 limit-req 限流实验 ==="
end=$((SECONDS + DURATION))
while [ $SECONDS -lt $end ]; do
  for _ in $(seq 1 50); do
    curl -s -o /dev/null -X POST "$GATEWAY_URL/api/v1/devices/g3-dev/reports" \
      -H "Content-Type: application/json" \
      -d '{"payload":{"temperature":25}}' &
  done
  wait
  sleep 0.05
done
echo "=== G3 完成：limit-req rate=10 burst=5，应有大量 429 ==="
```

- [ ] **Step 2: 运行**

```bash
chmod +x iot-learn-lab/scripts/scenario-g3-limit-req.sh
./iot-learn-lab/infra/apisix/bootstrap-device-report-gateway.sh limit-req
./iot-learn-lab/scripts/scenario-g3-limit-req.sh
```

- [ ] **Step 3: 对比 G2 vs G3 结果并记录**

在 `phase2-interview-notes.md` 中记录：limit-count 是窗口总量；limit-req 是平滑速率。

- [ ] **Step 4: Commit**

```bash
git add iot-learn-lab/scripts/scenario-g3-limit-req.sh
git commit -m "feat(phase2): add G3 limit-req load test script"
```

---

### Task 8: Grafana Gateway 行 Panel

**Files:**
- Modify: `iot-learn-lab/infra/grafana/dashboards/device-report-observability.json`

- [ ] **Step 1: 在 Grafana UI 新增 Row「Gateway (Phase 2)」**

添加 4 个 Panel（见场景 G4 表格）。

- [ ] **Step 2: 运行 G2 或 G3 产生 429 数据**

```bash
./iot-learn-lab/scripts/scenario-g2-limit-count.sh
```

- [ ] **Step 3: 截图并导出 JSON 回仓库**

- [ ] **Step 4: Commit**

```bash
git add iot-learn-lab/infra/grafana/dashboards/device-report-observability.json
git commit -m "feat(phase2): add gateway panels to observability dashboard"
```

---

### Task 9: 上游超时配置（G5）

- [ ] **Step 1: 更新 Upstream 实体 timeout（read=3s）**

本环境路由通过 `service_name` 引用 Upstream 实体 `device-report-upstream`（ID `00000000000000000158`），timeout 应改 **Upstream**，而非整段 PUT Route。

```bash
curl -s "${ADMIN_API}/apisix/admin/upstreams/${UPSTREAM_ID}" -X PATCH \
  -H "X-API-KEY: ${ADMIN_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "timeout": {"connect": 3, "send": 5, "read": 3}
  }' | jq .
```

验证：

```bash
curl -s "${ADMIN_API}/apisix/admin/upstreams/${UPSTREAM_ID}" \
  -H "X-API-KEY: ${ADMIN_KEY}" | jq '.value | {name, timeout, nodes}'
```

Expected：`name` 为 `device-report-upstream`，`timeout.read` 为 `3`。

- [ ] **Step 2: 为 debug 路由单独配置（若尚未创建，可选）**

debug 路由在 Dashboard 中可能尚未创建；若 `slow-query` 经网关返回 404，用 **自定义 Route ID** 新建：

```bash
curl -s "${ADMIN_API}/apisix/admin/routes/device-report-debug" -X PUT \
  -H "X-API-KEY: ${ADMIN_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "device-report-debug",
    "uri": "/api/v1/debug/*",
    "methods": ["POST"],
    "priority": 100,
    "upstream": {
      "type": "roundrobin",
      "nodes": {"192.168.16.1:8765": 1},
      "timeout": {"connect": 3, "send": 5, "read": 3}
    }
  }' | jq .
```

> 此处 `device-report-debug` 是**新建的自定义 Route ID**（环境中尚不存在，PUT 可创建）；与主路由的数字 ID 不冲突。

- [ ] **Step 3: 验证慢请求触发超时**

```bash
curl -s -o /dev/null -w "%{http_code}\n" -X POST \
  "${GATEWAY_URL}/api/v1/debug/slow-query?seconds=5"
```

Expected: **504** 或 **502**（>3s 的慢请求被网关切断）。

---

### Task 10: G5 压测脚本 + 与 Phase1 S4 联动

**Files:**
- Create: `iot-learn-lab/scripts/scenario-g5-upstream-timeout.sh`

- [ ] **Step 1: 编写脚本**

```bash
#!/usr/bin/env bash
# iot-learn-lab/scripts/scenario-g5-upstream-timeout.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATEWAY_URL="${GATEWAY_URL:-http://localhost:9080}"

echo "=== G5 上游超时 + 慢查询 ==="
echo "1) 经网关触发 5s 慢查询（网关 read timeout=3s）"
code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  "${GATEWAY_URL}/api/v1/debug/slow-query?seconds=5")
echo "slow-query via gateway: HTTP $code (expect 502/504)"

echo "2) 叠加正常上报流量 60s"
export BASE_URL="$GATEWAY_URL"
export DURATION=60
"$SCRIPT_DIR/scenario-s2-device-burst.sh"

echo "=== G5 完成：查看网关 502/504 与 HikariCP pending ==="
```

- [ ] **Step 2: 运行并观察 Grafana**

```bash
chmod +x iot-learn-lab/scripts/scenario-g5-upstream-timeout.sh
./iot-learn-lab/scripts/scenario-g5-upstream-timeout.sh
```

Expected: 网关 504 指标上升；应用 `hikaricp_connections_pending` 可能 > 0。

- [ ] **Step 3: Commit**

```bash
git add iot-learn-lab/scripts/scenario-g5-upstream-timeout.sh
git commit -m "feat(phase2): add G5 upstream timeout scenario script"
```

---

### Task 11: api-breaker 熔断（G6）

**Files:**
- Create: `iot-learn-lab/infra/apisix/plugin-config/api-breaker.json`
- Create: `iot-learn-lab/scripts/scenario-g6-downstream-down.sh`

- [ ] **Step 1: 路由启用 api-breaker（PATCH 插件，保留 Upstream 绑定）**

```bash
curl -s "${ADMIN_API}/apisix/admin/routes/${ROUTE_ID}" -X PATCH \
  -H "X-API-KEY: ${ADMIN_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "plugins": {
      "api-breaker": {
        "break_response_code": 503,
        "break_response_body": "{\"error\":\"circuit open\"}",
        "max_breaker_sec": 30,
        "unhealthy": {"http_statuses": [500, 502, 503, 504], "failures": 3},
        "healthy": {"http_statuses": [200, 201], "successes": 2}
      }
    }
  }' | jq .
```

实验结束后清除插件恢复 baseline：

```bash
./iot-learn-lab/infra/apisix/bootstrap-device-report-gateway.sh none
```

- [ ] **Step 2: 编写 G6 脚本**

```bash
#!/usr/bin/env bash
# iot-learn-lab/scripts/scenario-g6-downstream-down.sh
set -euo pipefail

GATEWAY_URL="${GATEWAY_URL:-http://localhost:9080}"

echo "=== G6 下游宕机 + 熔断 ==="
echo "请先在 Windows 停止 device-report-service，然后按 Enter 继续"
read -r _

echo "发送 10 个请求观察熔断..."
for i in $(seq 1 10); do
  code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    "$GATEWAY_URL/api/v1/devices/down-${i}/reports" \
    -H "Content-Type: application/json" \
    -d '{"payload":{"temperature":25}}')
  echo "request $i: HTTP $code"
  sleep 0.5
done

echo "=== 预期: 前几次 502/504，之后 503（熔断打开）==="
echo "恢复服务后等待 30s，再 curl 验证熔断关闭"
```

- [ ] **Step 3: 执行实验并记录**

1. Windows 停止 IDEA 中的 Spring Boot
2. 运行 G6 脚本
3. 重启服务，等待 `max_breaker_sec`，再验证 201 恢复

- [ ] **Step 4: Commit**

```bash
git add iot-learn-lab/infra/apisix/plugin-config/api-breaker.json
git add iot-learn-lab/scripts/scenario-g6-downstream-down.sh
git commit -m "feat(phase2): add api-breaker config and G6 downstream down script"
```

---

### Task 12: Phase 2 复盘文档

**Files:**
- Create: `iot-learn-lab/docs/phase2-interview-notes.md`

- [ ] **Step 1: 填写复盘模板**

```markdown
# Phase 2 网关层防护 — 复盘与面试笔记

## 实验记录

| 场景 | 插件/配置 | 关键现象 | 截图 |
|------|----------|---------|------|
| G1 基准线 | 无 | 网关 QPS ≈ 应用 QPS | |
| G2 limit-count | count=30/60s | 429 上升，应用 QPS 封顶 | |
| G3 limit-req | rate=10 burst=5 | 平滑限流，429 持续 | |
| G5 超时 | read=3s + slow 5s | 504/502 | |
| G6 熔断 | api-breaker | 503 circuit open | |

## 面试自答

1. 令牌桶和漏桶区别？limit-count 和 limit-req 各像什么？
2. 限流放在网关还是应用？本实验为什么先做网关？
3. 熔断和降级区别？api-breaker 做了什么？
4. 为什么必须配置 upstream timeout？
5. 网关 429 上升但应用 QPS 不变说明什么？
```

- [ ] **Step 2: Commit**

```bash
git add iot-learn-lab/docs/phase2-interview-notes.md
git commit -m "docs(phase2): add gateway protection interview notes"
```

---

### Task 13: 网关告警规则（可选）

> **注意：** `ApisixHigh429Rate` 基于 `apisix_http_status{code="429"}`，对 limit-count **不适用**。可选改为「入口 QPS 远高于应用 QPS」或保留给 limit-req/其他场景。详见 `iot-learn-lab/docs/phase2-apisix-prometheus-setup.md`。

**Files:**
- Create: `iot-learn-lab/infra/prometheus/alert-rules-gateway.yml`

- [ ] **Step 1: 添加告警规则**

```yaml
groups:
  - name: apisix-gateway
    rules:
      - alert: ApisixHigh429Rate
        expr: |
          sum(rate(apisix_http_status{code="429"}[5m]))
          / sum(rate(apisix_http_status[5m]))
          > 0.3
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "APISIX 429 比例超过 30%"

      - alert: ApisixHigh502Rate
        expr: |
          sum(rate(apisix_http_status{code=~"502|504"}[5m])) > 0.1
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "APISIX 502/504 错误率升高，检查下游或超时"
```

- [ ] **Step 2: 合并到 `/work/Metrics/prometheus/prometheus.yml` 的 rule_files**

```yaml
rule_files:
  - /etc/prometheus/alert-rules-device-report.yml
  - /etc/prometheus/alert-rules-gateway.yml
```

- [ ] **Step 3: 运行 G2/G6 验证 Firing**

- [ ] **Step 4: Commit**

```bash
git add iot-learn-lab/infra/prometheus/alert-rules-gateway.yml
git commit -m "feat(phase2): add APISIX gateway alert rules"
```

---

## APISIX Dashboard 操作速查（与 Task 对应）

**访问地址：**
- WSL 内：`http://localhost:9180/ui/routes`
- Windows 浏览器：`http://192.168.19.64:9180/ui/routes`

> Dashboard 按 **name**（`device-report-service`）显示路由；curl Admin API 需用 **Route ID**（`00000000000000000160`）。详见「APISIX Route ID 与 name」章节。

若偏好 UI 而非 curl，按以下顺序在 Dashboard 操作：

### 限流（G2 / G3）

1. **Routes** → `device-report-service` → **Edit**
2. **Plugins** → **+ Add Plugin** → 选 `limit-count` 或 `limit-req`
3. 填参数（见场景 G2/G3）→ **Submit**
4. **注意：** 同时只能保留一种限流插件做对比实验；切换前先 Disable 旧插件

### 超时（G5）

1. **Upstreams** → `device-report-upstream` → **Edit**（非 Routes 页）
2. 展开 **Timeout** → Connect/Send/Read 设为 3/5/3
3. Submit

### 熔断（G6）

1. **Plugins** → **+ Add Plugin** → `api-breaker`
2. 填 `unhealthy.failures=3`、`break_response_code=503`
3. Submit

---

## Spec 覆盖自检

| Spec 要求（Phase 2） | 对应 Task / 场景 |
|---------------------|-----------------|
| W3: limit-req / limit-count | Task 3–7, G2/G3 |
| W3: ab/wrk 压测观察 429 | Task 2,5,7 scripts |
| W4: APISIX 上游超时 | Task 9, G5 |
| W4: 模拟下游宕机 | Task 11, G6 |
| W4: pg_sleep 连接池打满 | Task 10 + Phase1 S4 联动 |
| 网关 vs 应用 QPS 对比 | G1, G4, Task 8 |
| 面试：令牌桶/漏桶、限流位置 | phase2-interview-notes.md |

无遗漏。

---

## Phase 2 完成标准（Checklist）

- [ ] `ROUTE_ID=00000000000000000160` 经 Admin API 可查到完整路由（非 null）
- [ ] 经 `localhost:9080`（WSL）或 `192.168.19.64:9080`（Windows 浏览器）网关上报成功
- [ ] APISIX Prometheus 两层配置完成（`config.yaml` + 路由 `prometheus` 插件）
- [ ] `limit-count` 实验：curl/G2 脚本 429 可观测；Prometheus 入口 QPS > 应用 QPS
- [ ] `limit-req` 实验：429 可观测，与 G2 对比已记录
- [ ] Grafana 有 Gateway 行（429、网关 vs 应用 QPS）
- [ ] 上游 timeout=3s + slow-query 5s → curl 经网关 **504**（不依赖 `http_status{code="504"}`）
- [ ] 下游宕机 + `api-breaker` → 503 熔断
- [ ] `phase2-interview-notes.md` 已填写
- [ ] （可选）网关告警规则可 Firing

---

## 参考

- Phase 1 计划：`docs/superpowers/plans/2026-07-02-phase1-observability.md`
- Phase 1 复盘：`iot-learn-lab/docs/phase1-interview-notes.md`
- **APISIX Prometheus 配置与排查：** `iot-learn-lab/docs/phase2-apisix-prometheus-setup.md`
- APISIX limit-count：https://apisix.apache.org/docs/apisix/plugins/limit-count/
- APISIX limit-req：https://apisix.apache.org/docs/apisix/plugins/limit-req/
- APISIX api-breaker：https://apisix.apache.org/docs/apisix/plugins/api-breaker/
