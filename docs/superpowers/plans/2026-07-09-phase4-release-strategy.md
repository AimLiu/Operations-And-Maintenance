# Phase 4 发布策略（金丝雀）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在本地 lab 模拟 **金丝雀发布**：同时运行 device-report **v1（:8765）** 与 **v2（:8766）**，经 APISIX 按权重分流（90/10）；注入 v2 缺陷后通过 Grafana 发现异常，并将权重 **回滚至 100% v1**。

**Architecture:** 外部流量经 APISIX（Phase 2 入口不变）→ **traffic-split / 加权 upstream** 将 90% 打到 v1、10% 打到 v2；v1/v2 均注册 **Nacos 服务发现**（同服务名、不同实例端口）。Prometheus 用 `version` label 区分 v1/v2 错误率与延迟；Phase 3 的 Sentinel/Feign **保持开启但不作为本阶段主角**（金丝雀实验时建议 APISIX 路由 **limit 插件 none**，避免与发布观测混淆）。

**Tech Stack:** Java 21, Spring Boot 3.3.5, Spring Cloud Alibaba 2023.0.1.2, Nacos Discovery 2.5, APISIX 3.13 `traffic-split`, Prometheus 2.55, Grafana 11.3

**Spec 来源:** `docs/superpowers/specs/2026-07-02-ops-learning-plan-design.md`（Phase 4 / W7–W8）

**前置条件（Phase 1–3 已完成）:**

- [x] `device-report-service` v1 运行在 Windows `:8765`，Prometheus Target UP
- [x] APISIX 路由 `device-report-service` → upstream 可达 `192.168.16.1:8765`
- [x] Grafana `device-report-observability` 含 Gateway + App + Sentinel 行
- [x] Nacos `:8848` 可访问（Phase 3 已用于 Sentinel 规则；本阶段扩展 **服务注册**）
- [ ] Phase 3 场景 R1–R6 已复盘（`phase3-interview-notes.md`）

**时间预算:** 2 周 × 10–15h = 20–30h

**与 Phase 5 边界:** 本阶段 **不** 做 Kafka 异步削峰；W10 终极演练再串联「限流→熔断→金丝雀回滚」。

---

## WSL2 + Windows 网络拓扑（Phase 4 扩展）

| 调用方 | 目标 | 地址 |
|--------|------|------|
| WSL 压测 / APISIX | device-report 金丝雀 | `localhost:9080` → **90%** `192.168.16.1:8765` + **10%** `192.168.16.1:8766` |
| device-report v1（稳定） | Windows IDEA | `:8765`，`app.version=v1` |
| device-report v2（金丝雀） | Windows IDEA 第二实例 | `:8766`，`app.version=v2` |
| Nacos 注册中心 | WSL Docker | `192.168.19.64:8848` |
| Prometheus | 抓取 v1 + v2 | `192.168.16.1:8765`、`192.168.16.1:8766` |

```
┌─ Windows ──────────────────────────────────────────────┐
│  device-report v1 :8765    device-report v2 :8766      │
│       │  Nacos 注册（同 service，不同 instance）         │
└───────┼────────────────────────────────────────────────┘
        ↑ APISIX traffic-split 90/10
┌─ WSL ─┴─ APISIX / Nacos / Prometheus / Grafana ─────────┘
```

> **记忆口诀：** 金丝雀 = **同路由、双端口、权重分流**；回滚 = **权重改回 100% v1**，无需立刻杀 v2 进程（可先保留观察）。

---

## 文件结构（本阶段新增/修改）

```
iot-learn-lab/
├── device-report-service/
│   ├── src/main/resources/
│   │   ├── application.yml              # v1 默认
│   │   └── application-v2.yml           # v2：8766 + 缺陷开关
│   └── src/main/java/.../
│       ├── config/CanaryBugConfig.java  # v2 缺陷开关（@RefreshScope + Service 层）
│       └── web/CanaryBugExceptionHandler.java
├── infra/
│   ├── apisix/
│   │   ├── bootstrap-canary-90-10.sh    # 权重 90/10
│   │   ├── bootstrap-canary-rollback.sh # 权重 100% v1
│   │   └── plugin-config/traffic-split-canary.json
│   ├── prometheus/
│   │   └── scrape-device-report-v2.yml
│   └── grafana/dashboards/
│       └── device-report-observability.json  # 新增 Canary 行
├── scripts/phase4/
│   ├── scenario-c1-dual-version-baseline.sh
│   ├── scenario-c2-canary-split-verify.sh
│   ├── scenario-c3-buggy-v2-errors.sh
│   └── scenario-c4-rollback-to-v1.sh
└── docs/
    ├── phase4-canary-runbook.md
    ├── phase4-release-checklist.md
    └── phase4-interview-notes.md
```

**环境变量（WSL 脚本）：**

```bash
export GATEWAY_URL="${GATEWAY_URL:-http://localhost:9080}"
export DIRECT_V1="${DIRECT_V1:-http://192.168.16.1:8765}"
export DIRECT_V2="${DIRECT_V2:-http://192.168.16.1:8766}"
export NACOS_ADDR="${NACOS_ADDR:-192.168.19.64:8848}"
```

---

## 学习场景编排（Phase 4 概览）

> **详细操作步骤与 PromQL** 见各 Task 末尾 **「验收与观测」** 及 `iot-learn-lab/docs/phase4-canary-runbook.md`（Task 13 产出）。

| 场景 | 业务背景 | 一句话预期 |
|------|----------|------------|
| **C1** 双版本基准 | 发布前 v1/v2 均健康 | Nacos 两实例 UP；直连各返回 201 |
| **C2** 90/10 分流 | 金丝雀放 10% 流量 | 网关流量 ≈ 9:1；两版本均有 QPS |
| **C3** v2 缺陷暴露 | 模拟 bug 版本上线 | **总错误率略升**；v2 5xx 显著高于 v1 |
| **C4** 回滚 v1 | 发布失败决策 | 权重 100% v1 后，总错误率恢复；v2 QPS→0 |
| **C5** 蓝绿对比（文档） | 理解切换方式差异 | 金丝雀=渐进；蓝绿=一次性切换（本 lab 以权重模拟） |
| **C6** 功能开关（可选） | Nacos 配置热开关缺陷 | 不重启 v2；`Refresh keys changed` 后行为立即变化（需 `@RefreshScope`） |

**推荐顺序：** C1 → C2 → C3 → C4 → 填写 release checklist + interview notes

---

## Phase 4 监控指标速查（按版本拆分）

| 观察点 | PromQL |
|--------|--------|
| v1 QPS | `sum(rate(http_server_requests_seconds_count{application="device-report-service",version="v1"}[1m]))` |
| v2 QPS | `sum(rate(http_server_requests_seconds_count{application="device-report-service",version="v2"}[1m]))` |
| v1 5xx rate | `sum(rate(http_server_requests_seconds_count{application="device-report-service",version="v1",status=~"5.."}[1m]))` |
| v2 5xx rate | `sum(rate(http_server_requests_seconds_count{application="device-report-service",version="v2",status=~"5.."}[1m]))` |
| 总错误率 | `sum(rate(http_server_requests_seconds_count{application="device-report-service",status=~"5.."}[1m])) / sum(rate(http_server_requests_seconds_count{application="device-report-service"}[1m]))` |
| v1 P99 | `histogram_quantile(0.99, sum(rate(http_server_requests_seconds_bucket{application="device-report-service",version="v1"}[1m])) by (le))` |
| v2 P99 | `histogram_quantile(0.99, sum(rate(http_server_requests_seconds_bucket{application="device-report-service",version="v2"}[1m])) by (le))` |
| 网关入口 QPS | `sum(rate(apisix_http_latency_count{type="request",route="device-report-service"}[1m]))` |

---

## Implementation Tasks

### Task 1: 接入 Nacos 服务发现（v1）

**Files:**
- Modify: `iot-learn-lab/device-report-service/pom.xml`
- Modify: `iot-learn-lab/device-report-service/src/main/resources/application.yml`
- Modify: `iot-learn-lab/device-report-service/src/main/java/com/iot/learn/devicereport/DeviceReportApplication.java`

- [ ] **Step 1: 添加 discovery 依赖**

```xml
<dependency>
    <groupId>com.alibaba.cloud</groupId>
    <artifactId>spring-cloud-starter-alibaba-nacos-discovery</artifactId>
</dependency>
```

- [ ] **Step 2: application.yml 增加注册与版本标签**

```yaml
spring:
  cloud:
    nacos:
      discovery:
        server-addr: ${NACOS_ADDR:192.168.19.64:8848}
        namespace: ${NACOS_NAMESPACE:public}
        group: DEFAULT_GROUP
        metadata:
          version: v1

app:
  version: v1

management:
  metrics:
    tags:
      application: device-report-service
      version: ${app.version:v1}
```

- [ ] **Step 3: 启用服务发现**

```java
@SpringBootApplication
@EnableDiscoveryClient
@EnableFeignClients
public class DeviceReportApplication { ... }
```

- [ ] **Step 4: 启动 v1，Nacos 控制台验证**

访问 Nacos → **服务管理 → 服务列表** → `device-report-service` → 应看到 **8765** 实例，`metadata.version=v1`。

- [ ] **Step 5: Commit**

```bash
git add iot-learn-lab/device-report-service/
git commit -m "feat(phase4): register device-report v1 to Nacos discovery"
```

**验收与观测（Task 1 完成后）**

| 检查项 | 预期 | 在哪里看 |
|--------|------|----------|
| Nacos 实例 | 1 个 healthy，`port=8765` | Nacos 控制台 |
| 应用健康 | `/actuator/health` UP | `curl $DIRECT_V1/actuator/health` |
| version 标签 | Prometheus 有 `version="v1"` | `http_server_requests_seconds_count{version="v1"}` 有样本 |

```promql
up{job="device-report-service", instance=~".*:8765"}
```

**效果说明：** 尚未分流，仅完成「可被发现」；为 APISIX/Nacos 联动打基础。

---

### Task 2: 启动 v2 实例（8766 + 缺陷开关）

**Files:**
- Create: `iot-learn-lab/device-report-service/src/main/resources/application-v2.yml`
- Create: `iot-learn-lab/device-report-service/src/main/java/com/iot/learn/devicereport/config/CanaryBugConfig.java`
- Create: `iot-learn-lab/device-report-service/src/main/java/com/iot/learn/devicereport/web/CanaryBugExceptionHandler.java`
- Modify: `DeviceReportService.java`（在 Service 层调用 `maybeFail()`）

- [ ] **Step 1: application-v2.yml**

```yaml
server:
  port: 8766

spring:
  application:
    name: device-report-service
  cloud:
    nacos:
      discovery:
        server-addr: ${NACOS_ADDR:192.168.19.64:8848}
        metadata:
          version: v2
      config:
        server-addr: ${NACOS_ADDR:192.168.19.64:8848}
        namespace: ${NACOS_NAMESPACE:public}
        group: DEFAULT_GROUP
        file-extension: yaml
  config:
    import:
      - optional:nacos:device-report-v2-app.yaml?group=DEFAULT_GROUP&refreshEnabled=true

app:
  version: v2
  # canary-bug-enabled 建议由 Nacos 配置中心管理（见 Task 7）；本地可临时覆盖

management:
  metrics:
    tags:
      application: device-report-service
      version: v2
```

> **IDEA 注意：** Active Profiles 填 `v2`，**不要**填 `application-v2.yml`。

- [ ] **Step 2: 缺陷注入（Service 层 + `@RefreshScope`，勿用 Servlet Filter）**

**为何不用 Filter：** Filter 在最高优先级直接 `setStatus(500)` 并 `return` 时，请求**不经过** Spring MVC 观测链，`http_server_requests_seconds_count{status="500"}` 可能无样本（见 Task 3 排查）。

**为何需要 `@RefreshScope`：** Nacos 推送后 `Environment` 会更新，但普通 Bean 在构造时注入的 `final boolean enabled` **不会变**；`@ConditionalOnProperty` 只在**启动时**决定是否创建 Bean，均无法实现热开关（见 Task 7 排查）。

```java
@Component
@RefreshScope
public class CanaryBugConfig {

    private final boolean enabled;

    public CanaryBugConfig(@Value("${app.canary-bug-enabled:false}") boolean enabled) {
        this.enabled = enabled;
        log.info("Canary bug config loaded: app.canary-bug-enabled={}", enabled);
    }

    public void maybeFail() {
        if (enabled && ThreadLocalRandom.current().nextBoolean()) {
            throw new CanaryBugException("canary-bug-simulated");
        }
    }
}
```

`DeviceReportService.saveReport()` 开头调用 `canaryBugConfig.maybeFail()`；`CanaryBugExceptionHandler` 将异常映射为 HTTP 500（**不要**对 Handler 使用 `@ConditionalOnProperty`）。

- [ ] **Step 3: IDEA 第二运行配置**

Main class 不变，增加 VM/Program 参数：

```
--spring.profiles.active=v2
```

或环境变量 `SPRING_PROFILES_ACTIVE=v2`。

- [ ] **Step 4: 验证 v2 独立可用**

```bash
curl -s -o /dev/null -w "%{http_code}\n" -X POST \
  "$DIRECT_V2/api/v1/devices/c1-dev/reports" \
  -H "Content-Type: application/json" \
  -d '{"payload":{"temperature":25}}'
# 多次执行：canary-bug-enabled=true 时约 50% 500、50% 201
```

- [ ] **Step 5: Nacos 应出现第二实例 8766，metadata.version=v2**

- [ ] **Step 6: Commit**

```bash
git add iot-learn-lab/device-report-service/
git commit -m "feat(phase4): add device-report v2 profile on 8766 with canary bug hook"
```

**验收与观测（Task 2 完成后）**

| 检查项 | 预期 |
|--------|------|
| Nacos 实例数 | **2**（8765 + 8766） |
| 直连 v2 | bug 开启时 5xx 比例 > 0 |
| v2 Prometheus | `version="v2"` 系列出现 |

```promql
sum(rate(http_server_requests_seconds_count{version="v2",status=~"5.."}[1m]))
/
sum(rate(http_server_requests_seconds_count{version="v2"}[1m]))
```

**效果说明：** C1 场景可完成「双版本共存」；此时 **未经网关** 即可看到 v2 错误率高于 v1（若 v2 bug 已开）。缺陷开关可通过 Nacos 热更新（Task 7），无需重启 v2。

---

### Task 3: Prometheus 抓取 v2（8766）

**Files:**
- Modify: `iot-learn-lab/infra/prometheus/scrape-device-report.yml`（或 prometheus.yml 追加）

- [ ] **Step 1: 增加 scrape job（同 job 多 target 或独立 job）**

```yaml
- job_name: device-report-service
  metrics_path: /actuator/prometheus
  static_configs:
    - targets:
        - 192.168.16.1:8765
        - 192.168.16.1:8766
      labels:
        env: learn
        service: device-report-service
```

- [ ] **Step 2: 重载 Prometheus 配置**

```bash
# docker compose 或 SIGHUP，视你环境而定
curl -X POST http://192.168.19.64:9090/-/reload
```

- [ ] **Step 3: Targets 页面两实例均为 UP**

- [ ] **Step 4: Commit**

```bash
git add iot-learn-lab/infra/prometheus/
git commit -m "feat(phase4): scrape device-report v1 and v2 for canary metrics"
```

**验收与观测（Task 3 完成后）**

```promql
up{job="device-report-service"}
# 应返回 2 条，均为 1
```

**效果说明：** Grafana 可按 `version` label 分面板对比 v1/v2。

**常见排查：`http_server_requests_seconds_count{version="v2",status=~"5.."}` 为 empty**

| 现象 | 可能原因 | 处理 |
|------|----------|------|
| `version="v2"` 也为 empty | Prometheus 未 scrape `8766` | 在 `scrape-device-report.yml` 增加 `192.168.16.1:8766` 并重载 |
| `version="v2"` 有数据，5xx empty | 5xx 由 Servlet Filter 直接写出，未进 MVC 指标 | 改用 Task 2 的 Service 层 `maybeFail()` 实现 |
| curl 有 500 但 PromQL 无 5xx | 同上，或压测后等待 15–30s 再查 | 确认 `/actuator/prometheus` 中是否有 `status="500"` |

```bash
curl -s http://192.168.16.1:8766/actuator/prometheus | grep 'version="v2"'
```

---

### Task 4: APISIX 金丝雀路由（90/10 权重）

**Files:**
- Create: `iot-learn-lab/infra/apisix/plugin-config/traffic-split-canary.json`
- Create: `iot-learn-lab/infra/apisix/bootstrap-canary-90-10.sh`
- Create: `iot-learn-lab/infra/apisix/bootstrap-canary-rollback.sh`

- [ ] **Step 1: 确认 Phase 4 实验前网关插件为 none（避免限流干扰）**

```bash
./iot-learn-lab/infra/apisix/bootstrap-device-report-gateway.sh none
```

- [ ] **Step 2: traffic-split 配置（双 upstream 节点权重）**

方案 A — **upstream 多节点 + nodes weight**（推荐，简单）：

```bash
# PATCH upstream，两节点 90/10
curl -s "${ADMIN_API}/apisix/admin/upstreams/${UPSTREAM_ID}" -X PATCH \
  -H "X-API-KEY: ${ADMIN_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "nodes": {
      "192.168.16.1:8765": 90,
      "192.168.16.1:8766": 10
    },
    "timeout": { "connect": 3, "send": 3, "read": 10 }
  }' | jq .
```

方案 B — **traffic-split 插件**（按路由百分比，文档见 APISIX 官方）。

- [ ] **Step 3: bootstrap-canary-90-10.sh 封装上述 PATCH**

- [ ] **Step 4: bootstrap-canary-rollback.sh 回滚权重**

```json
"nodes": {
  "192.168.16.1:8765": 100,
  "192.168.16.1:8766": 0
}
```

- [ ] **Step 5: 经网关抽样 100 次，粗验比例**

```bash
for i in $(seq 1 100); do
  curl -s -o /dev/null -w "%{http_code}\n" -X POST \
    "$GATEWAY_URL/api/v1/devices/split-$i/reports" \
    -H "Content-Type: application/json" \
    -d '{"payload":{"temperature":25}}'
done | sort | uniq -c
```

- [ ] **Step 6: Commit**

```bash
git add iot-learn-lab/infra/apisix/
git commit -m "feat(phase4): add APISIX canary 90/10 and rollback scripts"
```

**验收与观测（Task 4 完成后）**

| 检查项 | 预期 |
|--------|------|
| 网关分流 | v1:v2 QPS 约 **9:1**（统计窗口 1–5min） |
| 总入口 QPS | 与压测脚本一致 |

```promql
# 网关入口
sum(rate(apisix_http_latency_count{type="request",route="device-report-service"}[1m]))

# 分版本（经网关后到达各实例）
sum(rate(http_server_requests_seconds_count{version="v1"}[1m]))
sum(rate(http_server_requests_seconds_count{version="v2"}[1m]))
```

**效果说明：** C2 场景核心——**仅 10% 用户受影响** 是金丝雀的价值；面试强调「用小流量验证新版本」。

---

### Task 5: 场景脚本 C1–C4

**Files:**
- Create: `iot-learn-lab/scripts/phase4/scenario-c1-dual-version-baseline.sh`
- Create: `iot-learn-lab/scripts/phase4/scenario-c2-canary-split-verify.sh`
- Create: `iot-learn-lab/scripts/phase4/scenario-c3-buggy-v2-errors.sh`
- Create: `iot-learn-lab/scripts/phase4/scenario-c4-rollback-to-v1.sh`

- [ ] **Step 1: C1 — 双版本健康检查（不经网关）**

```bash
#!/usr/bin/env bash
set -euo pipefail
DIRECT_V1="${DIRECT_V1:-http://192.168.16.1:8765}"
DIRECT_V2="${DIRECT_V2:-http://192.168.16.1:8766}"
curl -sf "$DIRECT_V1/actuator/health"
curl -sf "$DIRECT_V2/actuator/health"
```

- [ ] **Step 2: C2 — 经网关 60s 压测 + 打印 v1/v2 QPS 提示**

继承 `scenario-s2-device-burst.sh` 逻辑，`BASE_URL=$GATEWAY_URL`。

- [ ] **Step 3: C3 — 确认 v2 bug 开启，网关 90/10，压测 60s**

脚本末尾提示查看 v2 5xx rate 与总错误率。

- [ ] **Step 4: C4 — 执行 rollback 脚本后再次压测**

```bash
./iot-learn-lab/infra/apisix/bootstrap-canary-rollback.sh
```

- [ ] **Step 5: chmod +x && Commit**

```bash
chmod +x iot-learn-lab/scripts/phase4/*.sh
git add iot-learn-lab/scripts/phase4/
git commit -m "feat(phase4): add canary scenario scripts C1-C4"
```

**验收与观测（Task 5 完成后）**

| 场景 | 关键现象 |
|------|----------|
| C1 | Nacos 2 实例；直连均 201（v2 bug 关） |
| C2 | `version=v1` QPS ≈ 9 × `version=v2` QPS |
| C3 | 总错误率上升但**可控**；v2 5xx >> v1 5xx |
| C4 | 回滚后 v2 QPS≈0；总错误率回落至 C2 水平 |

```promql
# C3 关键：v2 错误率
sum(rate(http_server_requests_seconds_count{version="v2",status=~"5.."}[5m]))
/
sum(rate(http_server_requests_seconds_count{version="v2"}[5m]))
```

---

### Task 6: Grafana「Canary / Release」行

**Files:**
- Modify: `iot-learn-lab/infra/grafana/dashboards/device-report-observability.json`

- [ ] **Step 1: 新增 Row「Canary (Phase 4)」**

| Panel | PromQL |
|-------|--------|
| v1 QPS | `sum(rate(http_server_requests_seconds_count{application="device-report-service",version="v1"}[1m]))` |
| v2 QPS | `sum(rate(http_server_requests_seconds_count{application="device-report-service",version="v2"}[1m]))` |
| v1 错误率 | `sum(rate(...{version="v1",status=~"5.."}[5m]))/sum(rate(...{version="v1"}[5m]))` |
| v2 错误率 | 同上 version=v2 |
| 总错误率 | 全 service 5xx 比例 |

- [ ] **Step 2: C3 压测时截图 v2 错误率尖峰；C4 回滚后截图恢复**

- [ ] **Step 3: Commit**

```bash
git add iot-learn-lab/infra/grafana/dashboards/device-report-observability.json
git commit -m "feat(phase4): add Grafana canary release panels"
```

**验收与观测（Task 6 完成后）**

**效果说明：** 发布可观测性 = **按版本看错误率**，而不是只看全局均值；10% 金丝雀时全局错误率 ≈ `0.1 × v2_error_rate`。

---

### Task 7: Nacos 功能开关（C6 可选）

**Files:**
- Modify: `application-v2.yml` — 支持从 Nacos 读取 `app.canary-bug-enabled`
- Modify: `CanaryBugConfig.java` — 使用 `@RefreshScope`（**禁止** `@ConditionalOnProperty`）
- Create: `iot-learn-lab/infra/nacos/app-canary-v2-config.yml`（DataId 模板）

- [ ] **Step 1: 引入 `spring-cloud-starter-alibaba-nacos-config`（若尚未引入）**

```xml
<dependency>
    <groupId>com.alibaba.cloud</groupId>
    <artifactId>spring-cloud-starter-alibaba-nacos-config</artifactId>
</dependency>
```

- [ ] **Step 2: `application-v2.yml` 配置 Nacos Config（仅 v2 profile 生效）**

```yaml
spring:
  cloud:
    nacos:
      discovery:
        server-addr: ${NACOS_ADDR:192.168.19.64:8848}
      config:
        server-addr: ${NACOS_ADDR:192.168.19.64:8848}   # 必须单独配置，不会继承 discovery
        namespace: ${NACOS_NAMESPACE:public}
        group: DEFAULT_GROUP
        file-extension: yaml
  config:
    import:
      - optional:nacos:device-report-v2-app.yaml?group=DEFAULT_GROUP&refreshEnabled=true
```

**Nacos 控制台配置（Data ID / Group / 格式必须一致）：**

| 字段 | 值 |
|------|-----|
| Data ID | `device-report-v2-app.yaml`（**含 `.yaml` 后缀**，与 `spring.config.import` 完全一致） |
| Group | `DEFAULT_GROUP` |
| 格式 | YAML |
| 内容示例 | 见下 |

```yaml
app:
  canary-bug-enabled: false   # C1/C2/C4 用 false；C3/C6 验证时改为 true
```

> **常见错误：** Nacos 里 Data ID 写成 `device-report-v2-app`（无后缀），而代码 import 的是 `device-report-v2-app.yaml` → 拉不到配置。`optional:` 前缀会导致**静默失败**（启动不报错），排查时可临时去掉 `optional:` 强制暴露错误。

- [ ] **Step 3: `CanaryBugConfig` 支持热更新**

```java
@Component
@RefreshScope   // Nacos 推送后重建 Bean，重新注入 @Value
public class CanaryBugConfig {
    // 不要使用 @ConditionalOnProperty — 只在启动时生效，热更新无效
}
```

- [ ] **Step 4: 不改 APISIX 权重，仅切换 bug 开关，观察 v2 错误率变化**

- [ ] **Step 5: Commit**

**验收与观测（Task 7 完成后）**

| 操作 | 预期 |
|------|------|
| Nacos 改 `canary-bug-enabled: false` | 数秒内 v2 直连不再出现 500，**无需重启** |
| Nacos 改回 `true` | 约 50% 500 恢复，日志出现 `Canary bug config loaded: ...=true` |
| 与 C4 对比 | C4 是**流量回滚**（APISIX 权重 100/0）；C6 是**功能开关**（修 bug 行为，流量仍可 10% 到 v2） |

**效果说明：** 区分 **流量回滚（APISIX 权重）** 与 **功能开关（配置热更新）**。

#### Nacos 配置同步排查指南

**如何判断 Nacos 层已成功（配置推送 OK）：**

启动或修改 Nacos 后，v2 日志应出现类似：

```text
[data-received] dataId=device-report-v2-app.yaml, group=DEFAULT_GROUP, ... content=app:
  canary-bug-enabled: false
Refresh keys changed: [app.canary-bug-enabled]
```

若看到以上日志，说明 **Nacos → Spring Environment 链路正常**；若业务行为仍未变，问题在 **Bean 未消费刷新**（见下）。

**如何判断业务层已生效：**

1. 修改 Nacos 后，日志应再出现：`Canary bug config loaded: app.canary-bug-enabled=false`（`@RefreshScope` 重建 Bean）
2. 直连 v2 连续 curl 10 次：`false` 时应全部 201；`true` 时约一半 500

```bash
for i in $(seq 1 10); do
  curl -s -o /dev/null -w "%{http_code}\n" -X POST \
    "http://192.168.16.1:8766/api/v1/devices/nacos-hot-$i/reports" \
    -H "Content-Type: application/json" \
    -d '{"payload":{"temperature":25}}'
done
```

**典型根因对照表**

| 症状 | 根因 | 处理 |
|------|------|------|
| 改了 Nacos 完全无日志 | Data ID 不匹配；或 v2 profile 未激活；或 `nacos.config.server-addr` 未配 | 对齐 Data ID；IDEA Profiles=`v2`；补全 config.server-addr |
| 有 `Refresh keys changed` 但仍 500 | `@ConditionalOnProperty` 或构造器 `final` 缓存旧值 | 改用 `@RefreshScope`，去掉 `@ConditionalOnProperty` |
| 启动报错找不到配置 | 去掉 `optional:` 后暴露；检查 Group/Namespace | 用 API 验证：`curl "http://192.168.19.64:8848/nacos/v1/cs/configs?dataId=device-report-v2-app.yaml&group=DEFAULT_GROUP"` |
| v1 实例误读 v2 配置 | `spring.config.import` 写在 `application-v2.yml` | 仅 v2 实例激活 `v2` profile 时会加载，v1 不受影响 |

**配置层 vs 业务层（面试可讲）：**

```
Nacos 推送 → ClientWorker 拉取 → RefreshEvent → Environment 更新
                                                      ↓
                              @RefreshScope Bean 重建 ← 必须，否则 maybeFail() 仍用旧 enabled
```

**可选：查看运行时绑定值**

临时暴露 `env` 端点后访问：

```text
http://192.168.16.1:8766/actuator/env/app.canary-bug-enabled
```

`Environment` 已是 `false` 但仍在抛 500 → 确认 `CanaryBugConfig` 已加 `@RefreshScope` 且 `DeviceReportService` 注入的是 Spring 管理的代理 Bean。

---

### Task 8: 发布 Checklist 文档

**Files:**
- Create: `iot-learn-lab/docs/phase4-release-checklist.md`

- [ ] **Step 1: 写入发布前/中/后检查项**

**发布前：**

- [ ] v2 单元/冒烟通过；`canary-bug-enabled=false` 冒烟
- [ ] Nacos 注册正常；Prometheus 双 target UP
- [ ] APISIX 权重脚本就绪；Grafana Canary 行可见

**发布中：**

- [ ] 权重 10% → 观察 15–30min：v2 错误率、P99、业务指标
- [ ] 错误率超阈值（示例：v2 5xx > 5% 持续 5m）→ 触发回滚

**发布后 / 回滚：**

- [ ] 执行 `bootstrap-canary-rollback.sh`
- [ ] 确认 v2 QPS≈0、总错误率恢复
- [ ] 复盘记录写入 `phase4-interview-notes.md`

- [ ] **Step 2: Commit**

```bash
git add iot-learn-lab/docs/phase4-release-checklist.md
git commit -m "docs(phase4): add canary release checklist"
```

---

### Task 9: 场景操作手册 phase4-canary-runbook.md

**Files:**
- Create: `iot-learn-lab/docs/phase4-canary-runbook.md`

- [ ] **Step 1:** 参照 `phase3-scenarios-runbook.md` 结构，写 C1–C4 操作步骤 + 每场景 PromQL + 预期表

- [ ] **Step 2:** 补充「三种发布策略对比表」（滚动 / 蓝绿 / 金丝雀）

| 策略 | 流量切换 | 资源占用 | 回滚速度 | 本 lab 模拟程度 |
|------|----------|----------|----------|----------------|
| 滚动 | 逐步替换实例 | 低 | 中 | 未完整模拟 |
| 蓝绿 | 一次性切换 | 高（双倍） | 快 | 可用 0/100 权重近似 |
| 金丝雀 | 按权重渐进 | 中 | 快 | **C2–C4 核心** |

- [ ] **Step 3: Commit**

---

### Task 10: 面试复盘模板 phase4-interview-notes.md

**Files:**
- Create: `iot-learn-lab/docs/phase4-interview-notes.md`

- [ ] **Step 1:** 预留 C3/C4 截图位、三道题自测：

1. 滚动 / 蓝绿 / 金丝雀优缺点？
2. 发布失败怎么发现？（错误率、P99、日志、告警）
3. 金丝雀与 Sentinel 熔断关系？（变更时 vs 运行时）

- [ ] **Step 2: Commit**

---

## W7 / W8 日程建议

| 天 | 场景 | 任务 | 时长 |
|----|------|------|------|
| D1 | C1 双版本 | Task 1–3 | 4h |
| D2 | C2 分流 | Task 4–5 | 4h |
| D3 | C3 缺陷 | Task 5–6 | 3h |
| D4 | C4 回滚 | Task 5–6 | 3h |
| D5 | C6 开关 + 文档 | Task 7–8 | 3h |
| D6 | 复盘 | Task 9–10 | 3h |

---

## Phase 4 完成检查清单

- [ ] v1 `:8765`、v2 `:8766` 同时运行，Nacos 两实例可见
- [ ] APISIX 90/10 分流可验证（v1:v2 QPS ≈ 9:1）
- [ ] v2 缺陷可在 Grafana 看到 **v2 错误率** 上升，总错误率可控
- [ ] `bootstrap-canary-rollback.sh` 后流量 100% v1，错误率恢复
- [ ] Grafana 有 Canary 行；`phase4-release-checklist.md` 已填写
- [ ] 能口述：金丝雀 vs 蓝绿 vs 滚动；发布观测 vs 运行时熔断（Phase 3）
- [ ] 能口述：Nacos 配置推送成功（`Refresh keys changed`）≠ 业务热更新生效（还需 `@RefreshScope`）

---

## 参考

- APISIX traffic-split: https://apisix.apache.org/docs/apisix/plugins/traffic-split/
- Nacos Discovery: https://nacos.io/docs/latest/guide/user/quick-start/
- Phase 2 网关指标语义: `iot-learn-lab/docs/phase2-apisix-prometheus-setup.md`
- Phase 3 韧性基线: `docs/superpowers/plans/2026-07-05-phase3-application-resilience.md`
