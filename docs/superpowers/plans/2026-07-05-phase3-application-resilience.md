# Phase 3 应用层韧性 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 Java 应用层接入 Sentinel（限流 / 熔断 / 降级），新增 `command-dispatch-service` 并通过 OpenFeign 与 `device-report-service` 串联；用 Nacos 持久化 Sentinel 规则、Redis 做降级兜底，完成「关下游 → 雪崩 vs 熔断保护」对比实验（Phase 3 / W5–W6）。

**Architecture:** 外部流量仍经 APISIX（Phase 2）进入 **Windows** 上 `device-report-service:8765`；上报落库后，可选调用 **同机** `command-dispatch-service:8767`（OpenFeign + Sentinel）。Nacos / Redis / PostgreSQL 在 **WSL Docker**，Windows 应用通过 `192.168.19.64` 访问。Prometheus 抓取两个 Spring Boot 的 `/actuator/prometheus`；Grafana 新增 **Sentinel + Feign 链路** 行，与 Phase 1 应用指标、Phase 2 网关指标对照。

**Tech Stack:** Java 21, Spring Boot 3.3.5, Spring Cloud 2023.0.3, Spring Cloud Alibaba 2023.0.1.2, OpenFeign, Sentinel, Nacos 2.5, Redis 7, PostgreSQL 16, Prometheus 2.55, Grafana 11.3, APISIX 3.13（入口不变）

**Spec 来源:** `docs/superpowers/specs/2026-07-02-ops-learning-plan-design.md`（Phase 3 / W5–W6）

**前置条件（Phase 1 + Phase 2 已完成）:**

- [x] `device-report-service` 运行在 Windows `:8765`，Prometheus Target UP
- [x] APISIX 路由 `device-report-service` → `192.168.16.1:8765` 正常
- [x] Grafana Dashboard `device-report-observability` 含应用层 + Gateway 行
- [x] WSL Docker 中 **Nacos**（`:8848`）、**Redis**（`:6379`）、**PostgreSQL**（`:5432`）可访问
- [ ] Phase 2 网关实验已复盘（`phase2-interview-notes.md`）；G5/G6 概念区分熔断(503) vs 超时(504)

**时间预算:** 2 周 × 10–15h = 20–30h

**与 Phase 4 边界:** 本阶段 **不** 做金丝雀双版本（8766 预留给 Phase 4）；Kafka 异步削峰留 Phase 5。

---

## WSL2 + Windows 网络拓扑（Phase 3 扩展）

在 Phase 2 拓扑基础上，增加 **Windows 双服务互调** 与 **Windows → WSL 中间件**：

| 调用方 | 目标 | 地址 |
|--------|------|------|
| WSL 压测 / APISIX | device-report（Windows） | 网关 `localhost:9080` → upstream `192.168.16.1:8765` |
| device-report（Windows） | command-dispatch（Windows） | **`http://localhost:8767`**（Feign，同机） |
| device-report（Windows） | PostgreSQL / Redis / Nacos（WSL） | **`192.168.19.64:5432 / :6379 / :8848`** |
| command-dispatch（Windows） | PostgreSQL / Redis / Nacos（WSL） | **`192.168.19.64:...`** |
| Prometheus（WSL） | 两个 Java 应用 | **`192.168.16.1:8765`**、**`192.168.16.1:8767`** |
| Sentinel Dashboard（可选） | WSL Docker | `http://192.168.19.64:8858` |

```
┌─ Windows ─────────────────────────────────────────────────────┐
│  device-report :8765 ──Feign──→ command-dispatch :8767       │
│       │                              │                         │
│       └────────── 192.168.19.64 ─────┴→ Nacos / Redis / PG   │
└───────────────────────────────────────────────────────────────┘
         ↑ APISIX upstream 192.168.16.1:8765
┌─ WSL ──┴─ APISIX / Prometheus / Grafana / Nacos / Redis / PG ─┘
```

> **记忆口诀：** Java 找 Java 用 `localhost`；Java 找 Docker 用 `192.168.19.64`；Docker 找 Java 用 `192.168.16.1`。

---

## 文件结构

```
Operations-And-Maintenance/
├── iot-learn-lab/
│   ├── pom.xml                                          # 增加 Spring Cloud Alibaba BOM
│   ├── device-report-service/                           # 改造：Feign + Sentinel + Redis
│   │   ├── pom.xml
│   │   └── src/main/java/com/iot/learn/devicereport/
│   │       ├── client/CommandDispatchClient.java      # OpenFeign
│   │       ├── config/SentinelConfig.java
│   │       ├── config/RedisConfig.java
│   │       ├── fallback/DispatchFallbackHandler.java
│   │       ├── controller/DeviceReportController.java   # 新增 reports-with-dispatch
│   │       └── service/DispatchOrchestrationService.java
│   ├── command-dispatch-service/                        # 新模块
│   │   ├── pom.xml
│   │   └── src/main/java/com/iot/learn/commanddispatch/
│   │       ├── CommandDispatchApplication.java
│   │       ├── controller/CommandDispatchController.java
│   │       ├── controller/DebugController.java
│   │       └── service/CommandDispatchService.java
│   ├── infra/
│   │   ├── sentinel/
│   │   │   ├── nacos-flow-rules-device-report.json
│   │   │   ├── nacos-degrade-rules-device-report.json
│   │   │   └── README-nacos-sentinel.md
│   │   ├── prometheus/
│   │   │   └── scrape-command-dispatch.yml
│   │   └── grafana/dashboards/
│   │       └── device-report-observability.json         # 追加 Sentinel / Feign 行
│   ├── scripts/
│   │   └── phase3/
│   │       ├── scenario-r1-feign-baseline.sh
│   │       ├── scenario-r2-sentinel-flow-block.sh
│   │       ├── scenario-r3-nacos-hot-reload.sh
│   │       ├── scenario-r4-avalanche-no-breaker.sh
│   │       ├── scenario-r5-avalanche-with-breaker.sh
│   │       └── scenario-r6-redis-fallback.sh
│   └── docs/
│       ├── phase2-apisix-prometheus-setup.md            # Phase 2 参考
│       ├── phase3-scenarios-runbook.md                  # R1–R6 操作手册
│       └── phase3-interview-notes.md                    # W5/W6 复盘（Task 14 产出）
└── docs/superpowers/plans/
    └── 2026-07-05-phase3-application-resilience.md      # 本文件
```

**环境变量约定（WSL 脚本，继承 Phase 2）：**

```bash
export GATEWAY_URL="${GATEWAY_URL:-http://localhost:9080}"
export DIRECT_URL="${DIRECT_URL:-http://192.168.16.1:8765}"
export DISPATCH_URL="${DISPATCH_URL:-http://192.168.16.1:8767}"
export NACOS_ADDR="${NACOS_ADDR:-192.168.19.64:8848}"
export REDIS_HOST="${REDIS_HOST:-192.168.19.64}"
```

---

## 实验架构

```
压测脚本 (WSL)
    ↓  localhost:9080
APISIX :9080  （Phase 2 网关；Phase 3 建议 bootstrap none，避免与 Sentinel 叠层干扰 R4/R5）
    ↓  192.168.16.1:8765
device-report-service (Windows)
    ├─ Sentinel 流控 / 熔断 / 降级（应用层第二道防线）
    ├─ PostgreSQL ← 192.168.19.64:5432
    ├─ Redis 缓存降级 ← 192.168.19.64:6379
    └─ OpenFeign → command-dispatch-service :8767 (localhost)
                        ├─ Sentinel（下游资源保护）
                        └─ PostgreSQL（可选，本实验可内存模拟）
    ↓
Prometheus 抓取 :8765 + :8767 + APISIX :9091
Grafana：Gateway 行 + App 行 + Sentinel 行
```

**双层防护对照（面试核心）：**

| 层级 | 组件 | 作用 | Phase |
|------|------|------|-------|
| L2 网关 | APISIX limit-count/limit-req/api-breaker | 入口粗限流 / 超时 / 网关熔断 | 2 |
| L3 应用 | Sentinel flow/degrade + fallback | 细粒度资源保护 / 快速失败 / 降级 | 3 |

---

## Phase 3 监控指标速查表

### Sentinel（应用层）

| 观察点 | 说明 | 典型 PromQL / 观测方式 |
|--------|------|------------------------|
| 通过 QPS | 未被 Sentinel 拦截 | Sentinel Dashboard；或 HTTP 201 rate（R2） |
| 阻塞 QPS | 被 flow 规则 block | Dashboard Block QPS；或 HTTP 429 rate（见 R2） |
| 降级 QPS | degrade 触发 fallback | 应用日志 + 响应体 `DEGRADED` / `fallback-` |
| RT | 资源响应时间 | Dashboard RT；或链路 P99 PromQL（见 R4/R5） |
| 线程池 | Tomcat 活跃线程（雪崩） | `jvm_threads_live_threads{application="device-report-service"}` |

> Sentinel 1.8+ 可通过 `spring.cloud.sentinel.eager=true` + Dashboard 观测；Grafana 行以 **应用 HTTP + 线程 + 日志** 为主，Dashboard 为辅。当前项目**未接入** `sentinel_block_requests_total` 等专用指标。

### Feign 链路

| 观察点 | PromQL |
|--------|--------|
| 上游 QPS | `sum(rate(http_server_requests_seconds_count{application="device-report-service",uri="/api/v1/devices/{deviceId}/reports-with-dispatch"}[1m]))` |
| command-dispatch QPS | `sum(rate(http_server_requests_seconds_count{application="command-dispatch-service"}[1m]))` |
| 链路 P99 | `histogram_quantile(0.99, sum(rate(http_server_requests_seconds_bucket{application="device-report-service",uri="/api/v1/devices/{deviceId}/reports-with-dispatch"}[1m])) by (le))` |
| 429 block QPS | `sum(rate(http_server_requests_seconds_count{application="device-report-service",uri="/api/v1/devices/{deviceId}/reports-with-dispatch",status="429"}[1m]))` |
| 双服务存活 | `up{job="device-report-service"}`、`up{job="command-dispatch-service"}` |

### 雪崩对比（R4 vs R5）

| 指标 | PromQL | 无 Sentinel 熔断（R4） | 有 degrade/fallback（R5） |
|------|--------|----------------------|---------------------------|
| dispatch Target | `up{job="command-dispatch-service"}` | DOWN | DOWN |
| 链路 P99 | 见上「链路 P99」 | **持续升高** | **保持低位** |
| 活跃线程 | `jvm_threads_live_threads{application="device-report-service"}` | 可能飙升 | 相对稳定 |
| dispatch QPS | `sum(rate(http_server_requests_seconds_count{application="command-dispatch-service"}[1m]))` | 可能有连接尝试 | ≈ 0 |
| 5xx rate | `sum(rate(http_server_requests_seconds_count{application="device-report-service",uri="/api/v1/devices/{deviceId}/reports-with-dispatch",status=~"5.."}[1m]))` | 可能升高 | 低（多为 201） |

---

## 学习场景编排（Phase 3 核心）

> **详细操作步骤、脚本命令与结果验证：** 见 [`iot-learn-lab/docs/phase3-scenarios-runbook.md`](../../iot-learn-lab/docs/phase3-scenarios-runbook.md)  
> **脚本目录：** `iot-learn-lab/scripts/phase3/scenario-r{1-6}-*.sh`

### 场景 R1：Feign 链路基准线（W5 Day 1）

**业务背景：** 设备上报成功后，需向下游下发 ACK 指令（模拟 IoT 指令通道）。

**API：** `POST /api/v1/devices/{deviceId}/reports-with-dispatch`

**操作：**

```bash
# 两个服务均在 IDEA 启动后
curl -s -X POST "http://localhost:8765/api/v1/devices/r1-dev/reports-with-dispatch" \
  -H "Content-Type: application/json" \
  -d '{"payload":{"temperature":25}}' | jq .
```

**预期：** HTTP 201，JSON 含 `reportId` 与 `dispatchAckId`；Prometheus 中两个应用 QPS 同步上升。

**Prometheus 观测：**

```promql
up{job="device-report-service"} == 1 and up{job="command-dispatch-service"} == 1

sum(rate(http_server_requests_seconds_count{
  application="device-report-service",
  uri="/api/v1/devices/{deviceId}/reports-with-dispatch"
}[1m]))

sum(rate(http_server_requests_seconds_count{application="command-dispatch-service"}[1m]))
```

---

### 场景 R2：Sentinel 流控 block（W5 Day 2–3）

**业务背景：** 大促期间限制「带指令下发」接口 QPS，保护 dispatch 服务。

**规则（Nacos / 代码二选一）：** 资源名 `dispatchAck`，QPS 阈值 5。

**操作：** `scenario-r2-sentinel-flow-block.sh` 持续 60s 压测 `reports-with-dispatch`。

**预期：** 部分请求返回 Sentinel block（HTTP 429）；Dashboard Block QPS > 0；dispatch 服务 QPS 被压在 ~5。

**Prometheus 观测：**

```promql
sum(rate(http_server_requests_seconds_count{
  application="device-report-service",
  uri="/api/v1/devices/{deviceId}/reports-with-dispatch",
  status="201"
}[1m]))

sum(rate(http_server_requests_seconds_count{
  application="device-report-service",
  uri="/api/v1/devices/{deviceId}/reports-with-dispatch",
  status="429"
}[1m]))

sum(rate(http_server_requests_seconds_count{application="command-dispatch-service"}[1m]))
```

---

### 场景 R3：Nacos 规则热更新（W5 Day 4）

**业务背景：** 运维在不重启应用的情况下调高限流阈值。

**操作：**

1. Nacos 控制台修改 `device-report-service-flow-rules` JSON，QPS 5 → 20
2. 再次运行 R2 脚本，观察 block 比例下降

**预期：** 无需重启 JVM，规则生效（`spring.cloud.sentinel.datasource` 刷新）。

**Prometheus 观测：** 对比修改 Nacos 前后，复用 R2 的 201 / 429 rate；阶段 B 的 201 应升高、429 应降低。

---

### 场景 R4：雪崩 — 无熔断（W6 Day 1–2）★ 面试重点

**业务背景：** `command-dispatch-service` 宕机，上游 Feign 同步调用阻塞，拖垮 `device-report-service`。

**操作：**

1. **关闭** Sentinel degrade 规则（或 `feign.sentinel.enabled=false` 做对比组）
2. IDEA **停止** `command-dispatch-service`
3. 运行 `scenario-r4-avalanche-no-breaker.sh`（60s 并发调用 `reports-with-dispatch`）

**预期（坏现象）：**

- device-report **P99 显著升高**（等待 Feign 超时，默认可能 60s）
- `jvm_threads_live_threads` 上升
- Grafana：dispatch Target **DOWN**，report QPS 仍高但响应慢

**面试话术：** 「网关熔断只能保护到网关边界；**服务间同步调用**若无应用层熔断，故障会向上游传导，形成雪崩。」

**Prometheus 观测：**

```promql
up{job="command-dispatch-service"} == 0

histogram_quantile(0.99,
  sum(rate(http_server_requests_seconds_bucket{
    application="device-report-service",
    uri="/api/v1/devices/{deviceId}/reports-with-dispatch"
  }[1m])) by (le)
)

jvm_threads_live_threads{application="device-report-service"}

sum(rate(http_server_requests_seconds_count{
  application="device-report-service",
  uri="/api/v1/devices/{deviceId}/reports-with-dispatch",
  status=~"5.."
}[1m]))
```

---

### 场景 R5：雪崩 — Sentinel 熔断 + fallback（W6 Day 3–4）★ 面试重点

**业务背景：** 同样关闭 dispatch，但启用 Sentinel degrade + fallback，上游快速失败。

**操作：**

1. 启用 degrade 规则：RT > 500ms 或异常比例 > 50%，时间窗口 10s
2. 配置 `DispatchFallbackHandler` 返回降级 ACK（`degraded: true`）
3. 停止 dispatch，运行 `scenario-r5-avalanche-with-breaker.sh`

**预期（好现象）：**

- device-report P99 **保持低位**（毫秒~几十毫秒级 fallback）
- HTTP 200，body 含 `"degraded":true`
- dispatch QPS ≈ 0（不再打挂掉的下游）

**对比：** 与 R4 截图并排写入 `phase3-interview-notes.md`。

**Prometheus 观测：** 与 R4 相同 PromQL，对比数值——P99 低、`jvm_threads_live` 稳定、`sum(rate(...{application="command-dispatch-service"}...))` ≈ 0。

---

### 场景 R6：Redis 降级兜底（W6 Day 5）

**业务背景：** dispatch 短暂不可用，返回最近一次成功 ACK 的缓存。

**操作：**

1. 正常调用若干次写入 Redis 缓存
2. 停止 dispatch，再请求同一 `deviceId`
3. 运行 `scenario-r6-redis-fallback.sh`

**预期：** 响应来自 Redis 缓存（`source: "redis-cache"`）；区别于 R5 的静态 fallback。

**Prometheus 观测：** Redis 命中无专用指标；辅助看链路 P99 低位 + dispatch QPS ≈ 0；最终以 `redis-cli GET dispatch:ack:{deviceId}` 与响应体为准。

---

### 场景 R7：Phase 3 综合演练（W6 复盘日）

**顺序：** R1 → R2 → R4（截图坏）→ R5（截图好）→ R6 → 填写 interview notes。

---

## W5 / W6 日程建议

| 天 | 场景 | 任务 | 时长 |
|----|------|------|------|
| D1 | R1 Feign 基准 | Task 1–4 | 4h |
| D2 | Sentinel 接入 | Task 5–6 | 4h |
| D3 | R2 流控 | Task 7–8 | 3h |
| D4 | R3 Nacos 持久化 | Task 9 | 3h |
| D5 | 复盘 W5 | Task 14（部分） | 2h |
| D6 | command-dispatch 完善 | Task 3–4 | 3h |
| D7 | R4 雪崩（无熔断） | Task 10–11 | 4h |
| D8 | R5 熔断 + fallback | Task 12 | 4h |
| D9 | R6 Redis 降级 | Task 13 | 3h |
| D10 | R7 综合演练 | Task 14 | 3h |

---

## Implementation Tasks

### Task 1: 父 POM 引入 Spring Cloud Alibaba

**Files:**
- Modify: `iot-learn-lab/pom.xml`

- [ ] **Step 1: 添加 BOM 与版本属性**

在 `<properties>` 增加：

```xml
<spring-cloud.version>2023.0.3</spring-cloud.version>
<spring-cloud-alibaba.version>2023.0.1.2</spring-cloud-alibaba.version>
```

在 `<dependencyManagement>` 增加：

```xml
<dependency>
  <groupId>org.springframework.cloud</groupId>
  <artifactId>spring-cloud-dependencies</artifactId>
  <version>${spring-cloud.version}</version>
  <type>pom</type>
  <scope>import</scope>
</dependency>
<dependency>
  <groupId>com.alibaba.cloud</groupId>
  <artifactId>spring-cloud-alibaba-dependencies</artifactId>
  <version>${spring-cloud-alibaba.version}</version>
  <type>pom</type>
  <scope>import</scope>
</dependency>
```

- [ ] **Step 2: 注册新模块**

```xml
<modules>
  <module>device-report-service</module>
  <module>command-dispatch-service</module>
</modules>
```

- [ ] **Step 3: 验证**

```bash
cd iot-learn-lab && mvn -q validate
```

Expected: BUILD SUCCESS

- [ ] **Step 4: Commit**

```bash
git add iot-learn-lab/pom.xml
git commit -m "feat(phase3): add Spring Cloud Alibaba BOM and command-dispatch module slot"
```

---

### Task 2: 创建 command-dispatch-service 骨架

**Files:**
- Create: `iot-learn-lab/command-dispatch-service/pom.xml`
- Create: `iot-learn-lab/command-dispatch-service/src/main/java/com/iot/learn/commanddispatch/CommandDispatchApplication.java`
- Create: `iot-learn-lab/command-dispatch-service/src/main/resources/application.yml`

- [ ] **Step 1: 子模块 POM**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <parent>
    <groupId>com.iot.learn</groupId>
    <artifactId>iot-learn-lab</artifactId>
    <version>0.1.0-SNAPSHOT</version>
  </parent>
  <artifactId>command-dispatch-service</artifactId>
  <dependencies>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-web</artifactId>
    </dependency>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-actuator</artifactId>
    </dependency>
    <dependency>
      <groupId>io.micrometer</groupId>
      <artifactId>micrometer-registry-prometheus</artifactId>
    </dependency>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-test</artifactId>
      <scope>test</scope>
    </dependency>
  </dependencies>
  <build>
    <plugins>
      <plugin>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-maven-plugin</artifactId>
      </plugin>
    </plugins>
  </build>
</project>
```

- [ ] **Step 2: application.yml**

```yaml
server:
  port: 8767

spring:
  application:
    name: command-dispatch-service

management:
  endpoints:
    web:
      exposure:
        include: health,info,prometheus,metrics
  metrics:
    tags:
      application: command-dispatch-service
```

- [ ] **Step 3: 启动类**

```java
package com.iot.learn.commanddispatch;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication
public class CommandDispatchApplication {
    public static void main(String[] args) {
        SpringApplication.run(CommandDispatchApplication.class, args);
    }
}
```

- [ ] **Step 4: 编译并 IDEA 启动**

```bash
mvn -pl command-dispatch-service -am compile
curl -s http://localhost:8767/actuator/health
```

Expected: `{"status":"UP"}`

- [ ] **Step 5: Commit**

```bash
git add iot-learn-lab/command-dispatch-service/
git commit -m "feat(phase3): scaffold command-dispatch-service on port 8767"
```

---

### Task 3: command-dispatch 业务与 Debug 端点

**Files:**
- Create: `CommandDispatchController.java`, `CommandDispatchService.java`, `DebugController.java`
- Create: DTO `DispatchAckRequest.java`, `DispatchAckResponse.java`

- [ ] **Step 1: 正常 ACK 接口**

```java
@RestController
@RequestMapping("/api/v1/commands")
public class CommandDispatchController {

    private final CommandDispatchService service;

    public CommandDispatchController(CommandDispatchService service) {
        this.service = service;
    }

    @PostMapping("/ack")
    public DispatchAckResponse ack(@Valid @RequestBody DispatchAckRequest request) {
        return service.ack(request);
    }
}
```

`CommandDispatchService.ack` 返回 `DispatchAckResponse(ackId, deviceId, "DISPATCHED")`。

- [ ] **Step 2: Debug 端点（R4/R5 用）**

```java
@RestController
@RequestMapping("/api/v1/debug")
public class DebugController {

    @PostMapping("/fail")
    public void fail() {
        throw new RuntimeException("simulated dispatch failure");
    }

    @PostMapping("/slow")
    public DispatchAckResponse slow(@RequestParam(defaultValue = "5") int seconds)
            throws InterruptedException {
        Thread.sleep(seconds * 1000L);
        return new DispatchAckResponse("slow-ack", "debug", "SLOW");
    }
}
```

- [ ] **Step 3: 验证**

```bash
curl -s -X POST http://localhost:8767/api/v1/commands/ack \
  -H "Content-Type: application/json" \
  -d '{"deviceId":"d1","reportId":1}' | jq .
```

Expected: JSON 含 `ackId`。

- [ ] **Step 4: Commit**

```bash
git add iot-learn-lab/command-dispatch-service/src/
git commit -m "feat(phase3): add command dispatch ack and debug endpoints"
```

---

### Task 4: device-report 接入 OpenFeign

**Files:**
- Modify: `iot-learn-lab/device-report-service/pom.xml`
- Create: `client/CommandDispatchClient.java`
- Create: `service/DispatchOrchestrationService.java`
- Modify: `DeviceReportController.java`
- Modify: `DeviceReportApplication.java`（`@EnableFeignClients`）

- [ ] **Step 1: 增加依赖**

```xml
<dependency>
  <groupId>org.springframework.cloud</groupId>
  <artifactId>spring-cloud-starter-openfeign</artifactId>
</dependency>
```

- [ ] **Step 2: Feign Client**

```java
@FeignClient(name = "command-dispatch-service", url = "${dispatch.base-url:http://localhost:8767}")
public interface CommandDispatchClient {

    @PostMapping("/api/v1/commands/ack")
    DispatchAckResponse ack(@RequestBody DispatchAckRequest request);
}
```

`application.yml` 追加：

```yaml
dispatch:
  base-url: http://localhost:8767
```

- [ ] **Step 3: 新端点（不破坏原有 `/reports`）**

```java
@PostMapping("/../{deviceId}/reports-with-dispatch")  // 实际路径见 Controller 映射
```

推荐在 `DeviceReportController` 同级新建 `DeviceReportDispatchController`：

```java
@RestController
@RequestMapping("/api/v1/devices/{deviceId}/reports-with-dispatch")
public class DeviceReportDispatchController {

    private final DispatchOrchestrationService orchestration;

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    public DeviceReportWithDispatchResponse postWithDispatch(
            @PathVariable String deviceId,
            @Valid @RequestBody DeviceReportRequest request) {
        return orchestration.saveAndDispatch(deviceId, request);
    }
}
```

`DispatchOrchestrationService`：先 `saveReport`，再 `commandDispatchClient.ack(...)`。

- [ ] **Step 4: 验证 R1**

```bash
curl -s -X POST http://localhost:8765/api/v1/devices/feign-1/reports-with-dispatch \
  -H "Content-Type: application/json" \
  -d '{"payload":{"temperature":25}}' | jq .
```

Expected: 201，含 `reportId` 与 `dispatchAckId`。

- [ ] **Step 5: Commit**

```bash
git add iot-learn-lab/device-report-service/
git commit -m "feat(phase3): add Feign client and reports-with-dispatch endpoint"
```

---

### Task 5: 接入 Sentinel（device-report）

**Files:**
- Modify: `device-report-service/pom.xml`
- Create: `config/SentinelConfig.java`
- Create: `fallback/DispatchFallbackHandler.java`
- Modify: `application.yml`

- [ ] **Step 1: 依赖**

```xml
<dependency>
  <groupId>com.alibaba.cloud</groupId>
  <artifactId>spring-cloud-starter-alibaba-sentinel</artifactId>
</dependency>
```

- [ ] **Step 2: application.yml**

```yaml
spring:
  cloud:
    sentinel:
      transport:
        dashboard: 192.168.19.64:8858
        port: 8719
      eager: true

feign:
  sentinel:
    enabled: true
```

- [ ] **Step 3: Fallback 类**

```java
@Component
public class DispatchFallbackHandler implements CommandDispatchClient {

    @Override
    public DispatchAckResponse ack(DispatchAckRequest request) {
        return new DispatchAckResponse(
            "fallback-" + UUID.randomUUID(),
            request.deviceId(),
            "DEGRADED",
            true
        );
    }
}
```

Feign 上配置 `fallback = DispatchFallbackHandler.class`（或使用 `@FeignClient(fallbackFactory=...)`）。

- [ ] **Step 4: 资源 @SentinelResource（可选显式）**

在 `DispatchOrchestrationService.saveAndDispatch` 上：

```java
@SentinelResource(value = "dispatchAck", fallback = "dispatchFallback")
public DeviceReportWithDispatchResponse saveAndDispatch(...) { ... }
```

- [ ] **Step 5: 验证应用启动**

Expected: 日志出现 Sentinel transport 连接 Dashboard（Dashboard 未启动时仅 warn，不阻塞启动）。

- [ ] **Step 6: Commit**

```bash
git add iot-learn-lab/device-report-service/
git commit -m "feat(phase3): integrate Sentinel and Feign fallback on device-report"
```

---

### Task 6: Sentinel Dashboard（可选 Docker）

**Files:**
- Create: `iot-learn-lab/infra/sentinel/docker-compose-sentinel-dashboard.yml`
- Create: `iot-learn-lab/infra/sentinel/README-nacos-sentinel.md`

- [ ] **Step 1: docker-compose**

```yaml
services:
  sentinel-dashboard:
    image: bladex/sentinel-dashboard:1.8.8
    container_name: sentinel-dashboard-learn
    ports:
      - "8858:8858"
    environment:
      JAVA_OPTS: "-Dserver.port=8858 -Dcsp.sentinel.dashboard.server=localhost:8858"
```

- [ ] **Step 2: 启动并登录**

```bash
docker compose -f iot-learn-lab/infra/sentinel/docker-compose-sentinel-dashboard.yml up -d
```

浏览器：`http://192.168.19.64:8858`（默认 sentinel/sentinel）。

- [ ] **Step 3: 确认 device-report 出现在「机器列表」**

- [ ] **Step 4: Commit**

```bash
git add iot-learn-lab/infra/sentinel/
git commit -m "feat(phase3): add Sentinel Dashboard docker compose"
```

---

### Task 7: Nacos 持久化 Sentinel 规则

**Files:**
- Create: `iot-learn-lab/infra/sentinel/nacos-flow-rules-device-report.json`
- Modify: `device-report-service/src/main/resources/application.yml`

- [ ] **Step 1: flow 规则 JSON（QPS=5 用于 R2）**

```json
[
  {
    "resource": "dispatchAck",
    "limitApp": "default",
    "grade": 1,
    "count": 5,
    "strategy": 0,
    "controlBehavior": 0,
    "clusterMode": false
  }
]
```

- [ ] **Step 2: application.yml datasource**

```yaml
spring:
  cloud:
    sentinel:
      datasource:
        flow:
          nacos:
            server-addr: ${NACOS_ADDR:192.168.19.64:8848}
            dataId: device-report-service-flow-rules
            groupId: SENTINEL_GROUP
            rule-type: flow
        degrade:
          nacos:
            server-addr: ${NACOS_ADDR:192.168.19.64:8848}
            dataId: device-report-service-degrade-rules
            groupId: SENTINEL_GROUP
            rule-type: degrade
```

- [ ] **Step 3: 在 Nacos 控制台创建配置**

Data ID: `device-report-service-flow-rules`，Group: `SENTINEL_GROUP`，内容为上 JSON。

- [ ] **Step 4: 重启 device-report，R2 压测验证 block**

- [ ] **Step 5: Commit**

```bash
git add iot-learn-lab/infra/sentinel/nacos-flow-rules-device-report.json
git add iot-learn-lab/device-report-service/src/main/resources/application.yml
git commit -m "feat(phase3): add Nacos datasource for Sentinel flow rules"
```

---

### Task 8: degrade 规则与 R2 压测脚本

**Files:**
- Create: `iot-learn-lab/infra/sentinel/nacos-degrade-rules-device-report.json`
- Create: `iot-learn-lab/scripts/scenario-r2-sentinel-flow-block.sh`

- [ ] **Step 1: degrade 规则（R5 用，R4 时从 Nacos 删除或禁用）**

```json
[
  {
    "resource": "dispatchAck",
    "grade": 0,
    "count": 500,
    "timeWindow": 10,
    "minRequestAmount": 5,
    "statIntervalMs": 1000,
    "slowRatioThreshold": 0.5
  }
]
```

- [ ] **Step 2: R2 脚本**

```bash
#!/usr/bin/env bash
# iot-learn-lab/scripts/scenario-r2-sentinel-flow-block.sh
set -euo pipefail
BASE_URL="${DIRECT_URL:-http://192.168.16.1:8765}"
DURATION="${DURATION:-60}"
echo "=== R2 Sentinel flow block ==="
end=$((SECONDS + DURATION))
while [ $SECONDS -lt $end ]; do
  for i in $(seq 1 10); do
    curl -s -o /dev/null -w "%{http_code}\n" -X POST \
      "$BASE_URL/api/v1/devices/r2-${i}/reports-with-dispatch" \
      -H "Content-Type: application/json" \
      -d '{"payload":{"temperature":25}}' &
  done
  wait
  sleep 0.2
done
echo "=== R2 完成：查看 Sentinel Dashboard Block QPS ==="
```

- [ ] **Step 3: chmod + 运行**

```bash
chmod +x iot-learn-lab/scripts/scenario-r2-sentinel-flow-block.sh
./iot-learn-lab/scripts/scenario-r2-sentinel-flow-block.sh
```

- [ ] **Step 4: Commit**

```bash
git add iot-learn-lab/scripts/scenario-r2-sentinel-flow-block.sh
git add iot-learn-lab/infra/sentinel/nacos-degrade-rules-device-report.json
git commit -m "feat(phase3): add degrade rules template and R2 flow block script"
```

---

### Task 9: Prometheus 抓取 command-dispatch

**Files:**
- Create: `iot-learn-lab/infra/prometheus/scrape-command-dispatch.yml`

- [ ] **Step 1: scrape 片段**

```yaml
- job_name: command-dispatch-service
  metrics_path: /actuator/prometheus
  static_configs:
    - targets:
        - 192.168.16.1:8767
      labels:
        env: learn
        service: command-dispatch-service
```

- [ ] **Step 2: 合并到 `/work/Metrics/prometheus/prometheus.yml` 并 reload**

```bash
curl -X POST http://localhost:9090/-/reload
```

Expected: Target `command-dispatch-service` UP。

- [ ] **Step 3: Commit**

```bash
git add iot-learn-lab/infra/prometheus/scrape-command-dispatch.yml
git commit -m "feat(phase3): add Prometheus scrape config for command-dispatch"
```

---

### Task 10: R4 雪崩脚本（无熔断对照组）

**Files:**
- Create: `iot-learn-lab/scripts/scenario-r4-avalanche-no-breaker.sh`

- [ ] **Step 1: 实验前检查清单**

```bash
# 1. Nacos 中暂时删除 degrade 规则，或 feign.sentinel.enabled=false
# 2. 停止 command-dispatch-service（IDEA Stop）
# 3. 确认 feign 超时：spring.cloud.openfeign.client.config.default.connectTimeout=3000
#                               readTimeout=10000
```

- [ ] **Step 2: 脚本**

```bash
#!/usr/bin/env bash
# iot-learn-lab/scripts/scenario-r4-avalanche-no-breaker.sh
set -euo pipefail
BASE_URL="${DIRECT_URL:-http://192.168.16.1:8765}"
DURATION="${DURATION:-60}"
echo "=== R4 雪崩对照组（无熔断）==="
echo "请确认 command-dispatch-service 已停止，按 Enter 继续"
read -r _
end=$((SECONDS + DURATION))
while [ $SECONDS -lt $end ]; do
  for i in $(seq 1 20); do
    curl -s -o /dev/null -w "%{http_code} %{time_total}s\n" -X POST \
      "$BASE_URL/api/v1/devices/r4-${i}/reports-with-dispatch" \
      -H "Content-Type: application/json" \
      -d '{"payload":{"temperature":25}}' &
  done
  wait
done
echo "=== R4 完成：查看 device-report P99、jvm_threads_live ==="
```

- [ ] **Step 3: 运行并 Grafana 截图 P99 升高**

- [ ] **Step 4: Commit**

```bash
git add iot-learn-lab/scripts/scenario-r4-avalanche-no-breaker.sh
git commit -m "feat(phase3): add R4 avalanche script without circuit breaker"
```

---

### Task 11: Feign 超时配置文档化

**Files:**
- Modify: `device-report-service/src/main/resources/application.yml`

- [ ] **Step 1: 显式 Feign 超时（便于观察 R4 慢等待）**

```yaml
spring:
  cloud:
    openfeign:
      client:
        config:
          default:
            connectTimeout: 3000
            readTimeout: 10000
```

- [ ] **Step 2: 在 `phase3-interview-notes.md` 记录 R4 现象**

- [ ] **Step 3: Commit**

```bash
git add iot-learn-lab/device-report-service/src/main/resources/application.yml
git commit -m "feat(phase3): configure Feign timeouts for avalanche demo"
```

---

### Task 12: R5 雪崩脚本（有熔断 + fallback）

**Files:**
- Create: `iot-learn-lab/scripts/scenario-r5-avalanche-with-breaker.sh`

- [ ] **Step 1: 启用 degrade + fallback**

1. Nacos 恢复 `device-report-service-degrade-rules`
2. `feign.sentinel.enabled=true`
3. 停止 dispatch

- [ ] **Step 2: 脚本（结构同 R4）**

```bash
#!/usr/bin/env bash
# iot-learn-lab/scripts/scenario-r5-avalanche-with-breaker.sh
# 内容同 R4，标题改为 R5；预期 time_total 显著更短，响应含 degraded
```

- [ ] **Step 3: 对比 R4/R5 截图写入 interview notes**

- [ ] **Step 4: Commit**

```bash
git add iot-learn-lab/scripts/scenario-r5-avalanche-with-breaker.sh
git commit -m "feat(phase3): add R5 avalanche script with Sentinel degrade"
```

---

### Task 13: Redis 降级缓存（R6）

**Files:**
- Modify: `device-report-service/pom.xml`
- Create: `config/RedisConfig.java`
- Modify: `DispatchOrchestrationService.java` / `DispatchFallbackHandler.java`

- [ ] **Step 1: 依赖**

```xml
<dependency>
  <groupId>org.springframework.boot</groupId>
  <artifactId>spring-boot-starter-data-redis</artifactId>
</dependency>
```

- [ ] **Step 2: application.yml**

```yaml
spring:
  data:
    redis:
      host: 192.168.19.64
      port: 6379
```

- [ ] **Step 3: 成功 dispatch 后写缓存**

```java
redisTemplate.opsForValue().set(
    "dispatch:ack:" + deviceId,
    objectMapper.writeValueAsString(response),
    Duration.ofMinutes(5));
```

Fallback 时优先 `GET dispatch:ack:{deviceId}`，命中则 `source=redis-cache`。

- [ ] **Step 4: R6 脚本 `scenario-r6-redis-fallback.sh`**

- [ ] **Step 5: Commit**

```bash
git add iot-learn-lab/device-report-service/
git add iot-learn-lab/scripts/scenario-r6-redis-fallback.sh
git commit -m "feat(phase3): add Redis cache fallback for dispatch ack"
```

---

### Task 14: Grafana Sentinel 行 + 复盘文档

**Files:**
- Modify: `iot-learn-lab/infra/grafana/dashboards/device-report-observability.json`
- Create: `iot-learn-lab/docs/phase3-interview-notes.md`

- [ ] **Step 1: Grafana 新增 Row「Sentinel / Feign (Phase 3)」**

| Panel | PromQL |
|-------|--------|
| Report-with-dispatch QPS | `sum(rate(http_server_requests_seconds_count{application="device-report-service",uri="/api/v1/devices/{deviceId}/reports-with-dispatch"}[1m]))` |
| Dispatch QPS | `sum(rate(http_server_requests_seconds_count{application="command-dispatch-service"}[1m]))` |
| Report P99 | `histogram_quantile(0.99, sum(rate(http_server_requests_seconds_bucket{application="device-report-service"}[1m])) by (le))` |
| Live Threads | `jvm_threads_live_threads{application="device-report-service"}` |

- [ ] **Step 2: phase3-interview-notes.md 模板**

```markdown
# Phase 3 应用层韧性 — 复盘与面试笔记

## 实验记录

| 场景 | 配置 | 关键现象 | 截图 |
|------|------|---------|------|
| R1 Feign 基准 | 双服务 UP | 链路 QPS 同步 | |
| R2 Sentinel flow | QPS=5 | Block QPS > 0 | |
| R4 雪崩无熔断 | dispatch DOWN | P99 升高、线程增 | |
| R5 雪崩有熔断 | degrade+fallback | P99 低、degraded:true | |
| R6 Redis | 缓存命中 | source=redis-cache | |

## 面试自答（修订版）

1. 令牌桶 / 漏桶 / limit-count / limit-req 区别？
2. 限流放网关还是应用？为何两层都要？
3. 熔断 vs 降级 vs 限流？
4. api-breaker(503) vs Sentinel degrade vs APISIX 504 timeout 区别？
5. 雪崩怎么一步步发生？R4/R5 对照说明了什么？
6. Hystrix 和 Sentinel 区别？为何选 Sentinel？
```

- [ ] **Step 3: Commit**

```bash
git add iot-learn-lab/infra/grafana/dashboards/device-report-observability.json
git add iot-learn-lab/docs/phase3-interview-notes.md
git commit -m "docs(phase3): add Grafana sentinel row and interview notes template"
```

---

## Spec 覆盖自检

| Spec 要求（Phase 3 / W5–W6） | 对应 Task / 场景 |
|-----------------------------|-----------------|
| W5: 雪崩链路理论 | R4/R5 + interview notes |
| W5: Sentinel + Nacos 持久化 | Task 5–9, R2/R3 |
| W5: QPS 限流 + fallback | Task 5–8, R2 |
| W6: command-dispatch-service | Task 2–3 |
| W6: Feign + 熔断 | Task 4–5, R4/R5 |
| W6: Redis 降级 | Task 13, R6 |
| W6: 关下游对比有无熔断 | R4 vs R5 |
| 架构图 Kafka 异步 | **Phase 5 实现**（本计划仅架构预留，不阻塞 Phase 3） |

无遗漏（Kafka 明确延后）。

---

## Phase 3 完成标准（Checklist）

- [ ] `command-dispatch-service` 在 `:8767` 启动，Prometheus Target UP
- [ ] `reports-with-dispatch` 经 Feign 打通（R1）
- [ ] Sentinel flow 规则生效，R2 可观测 block
- [ ] Nacos 修改规则无需重启（R3）
- [ ] R4：dispatch DOWN 时 device-report P99 恶化（无熔断）
- [ ] R5：同样条件下 fallback 快速返回（有 degrade）
- [ ] R6：Redis 缓存降级可命中
- [ ] Grafana 有 Sentinel/Feign 行
- [ ] `phase3-interview-notes.md` 已填写（含 R4/R5 对比截图）
- [ ] APISIX 网关实验与 Sentinel **分层理解**（G6 api-breaker vs R5 degrade）

---

## 参考

- Phase 1 计划：`docs/superpowers/plans/2026-07-02-phase1-observability.md`
- Phase 2 计划：`docs/superpowers/plans/2026-07-03-phase2-gateway-protection.md`
- APISIX 指标语义：`iot-learn-lab/docs/phase2-apisix-prometheus-setup.md`
- Sentinel 官方：https://sentinelguard.io/zh-cn/docs/introduction.html
- Spring Cloud Alibaba Sentinel：https://github.com/alibaba/spring-cloud-alibaba/wiki/Sentinel
- Nacos 配置管理：https://nacos.io/docs/latest/guide/user/config/
