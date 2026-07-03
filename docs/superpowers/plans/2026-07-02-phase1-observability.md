# Phase 1 可观测性实验 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 搭建 IoT 设备上报实验服务 `device-report-service`，接入 Prometheus + Grafana，完成 5 个可复现的学习场景监控，并在 W2 配置告警规则与 APISIX 健康修复。

**Architecture:** Spring Boot 3 应用通过 Micrometer 暴露 `/actuator/prometheus` 指标；Prometheus 抓取应用与 APISIX；Grafana 展示 RED（Rate/Errors/Duration）+ JVM + HikariCP 连接池；PostgreSQL 存储设备上报记录。学习采用「场景驱动」：每个场景有明确业务背景、要看的指标、预期曲线变化。

**Tech Stack:** Java 21, Maven 多模块, Spring Boot 3.3, Spring Data JPA, PostgreSQL 16, Micrometer, Prometheus 2.55, Grafana 11.3, APISIX 3.13（device-report-service 默认端口 **8765**）

**Spec 来源:** `docs/superpowers/specs/2026-07-02-ops-learning-plan-design.md`（Phase 1 / W1–W2）

**时间预算:** 2 周 × 10–15h = 20–30h

---

## 文件结构

```
Operations-And-Maintenance/
├── iot-learn-lab/
│   ├── pom.xml                         # 父 POM（packaging=pom, Java 21）
│   ├── device-report-service/          # Spring Boot 子模块
│   │   ├── pom.xml
│   │   └── src/
│   │       ├── main/java/com/iot/learn/devicereport/
│   │       │   ├── DeviceReportApplication.java
│   │       │   ├── controller/
│   │       │   │   ├── DeviceReportController.java
│   │       │   │   └── DebugController.java          # 场景3/4 故障注入
│   │       │   ├── service/
│   │       │   │   └── DeviceReportService.java
│   │       │   ├── repository/
│   │       │   │   └── DeviceReportRepository.java
│   │       │   ├── entity/
│   │       │   │   └── DeviceReport.java
│   │       │   └── dto/
│   │       │       ├── DeviceReportRequest.java
│   │       │       └── DeviceReportResponse.java
│   │       ├── main/resources/
│   │       │   └── application.yml
│   │       └── test/java/com/iot/learn/devicereport/
│   │           ├── controller/DeviceReportControllerTest.java
│   │           └── service/DeviceReportServiceTest.java
│   ├── infra/
│   │   ├── postgres/
│   │   │   └── init-iot-learn.sql      # 建库建表（在 postgres-alpine 执行）
│   │   ├── prometheus/
│   │   │   └── scrape-device-report.yml  # 追加 scrape job 片段
│   │   ├── grafana/
│   │   │   ├── dashboards/
│   │   │   │   └── device-report-observability.json
│   │   │   └── provisioning/
│   │   │       ├── datasources/prometheus.yml
│   │   │       └── dashboards/default.yml
│   │   └── alertmanager/               # W2 可选
│   │       └── alertmanager.yml
│   └── scripts/
│       ├── scenario-s1-health-check.sh
│       ├── scenario-s2-device-burst.sh
│       ├── scenario-s3-error-injection.sh
│       ├── scenario-s4-db-pressure.sh
│       └── scenario-s5-alert-verify.sh
└── docs/superpowers/plans/
    └── 2026-07-02-phase1-observability.md   # 本文件
```

---

## Phase 1 监控指标速查表

### 黄金信号与 RED 方法映射

| 黄金信号 | RED 维度 | Prometheus 指标（Micrometer 默认名） | 含义 | 正常参考值（本实验） |
|---------|---------|--------------------------------------|------|---------------------|
| 流量 Traffic | Rate | `rate(http_server_requests_seconds_count{application="device-report-service"}[1m])` | 每秒请求数 QPS | 空闲时 ≈0；S2 压测时 50–200/s |
| 错误 Errors | Errors | `sum(rate(http_server_requests_seconds_count{status=~"5.."}[5m])) / sum(rate(http_server_requests_seconds_count[5m]))` | 5xx 错误率 | < 1%；S3 注入时 > 5% |
| 延迟 Latency | Duration | `histogram_quantile(0.99, sum(rate(http_server_requests_seconds_bucket[5m])) by (le))` | P99 响应时间 | < 200ms；S4 慢查询时 > 500ms |
| 饱和度 Saturation | — | `hikaricp_connections_active / hikaricp_connections_max` | 连接池使用率 | < 70%；S4 压力时 > 90% |
| 饱和度 Saturation | — | `jvm_memory_used_bytes{area="heap"} / jvm_memory_max_bytes{area="heap"}` | JVM 堆使用率 | < 80% |

### JVM 指标

| 指标 | PromQL 示例 | 何时关注 |
|------|------------|---------|
| 堆内存使用 | `jvm_memory_used_bytes{area="heap"}` | 内存泄漏、OOM 前兆 |
| GC 暂停 | `rate(jvm_gc_pause_seconds_sum[5m])` | GC 频繁导致延迟抖动 |
| 活跃线程 | `jvm_threads_live_threads` | 线程泄漏、雪崩前兆（Phase 3 深入） |

### HikariCP 连接池指标

| 指标 | PromQL 示例 | 何时关注 |
|------|------------|---------|
| 活跃连接 | `hikaricp_connections_active{pool="HikariPool-1"}` | 接近 max 说明 DB 压力大 |
| 空闲连接 | `hikaricp_connections_idle` | 长期为 0 说明池子紧张 |
| 等待连接 | `hikaricp_connections_pending` | **> 0 即危险信号**，请求在排队等连接 |
| 最大连接 | `hikaricp_connections_max` | 配置核对用 |

### APISIX 网关指标（W2）

| 指标 | PromQL 示例 | 何时关注 |
|------|------------|---------|
| 网关 QPS | `sum(rate(apisix_http_status{route=~".*device.*"}[1m]))` | 入口流量趋势 |
| 网关 5xx | `sum(rate(apisix_http_status{code=~"5.."}[5m]))` | 网关层错误 |
| 上游延迟 | `histogram_quantile(0.99, sum(rate(apisix_http_latency_bucket[5m])) by (le))` | 网关到后端的 P99 |

### SLI / SLO 定义（本实验）

| SLI | 计算方式 | 实验 SLO | 告警阈值（W2） |
|-----|---------|---------|---------------|
| 可用性 | `up{job="device-report-service"}` | 99.9% | `up == 0` 持续 1m |
| 错误率 | 5xx / 总请求 | < 1% | > 5% 持续 2m |
| 延迟 | P99 响应时间 | < 200ms | > 500ms 持续 3m |
| 连接池 | pending connections | = 0 | > 0 持续 1m |

---

## 学习场景编排（Phase 1 核心）

### 场景 S1：服务健康巡检（W1 Day 1–2）

**业务背景：** 运维每天早上第一件事——确认 IoT 上报服务是否存活。

**操作：** 启动 `device-report-service`，访问 `GET /actuator/health`。

**监控面板：** Overview 行 — 服务状态、UP 指标、JVM 堆内存。

**关键指标：**
```promql
up{job="device-report-service"}
jvm_memory_used_bytes{area="heap", application="device-report-service"}
```

**预期结果：**
- `up == 1`
- 堆内存使用率在 20%–40%（刚启动）
- `/actuator/health` 返回 `{"status":"UP"}`

**面试话术：** 「我们用最基础的 `up` 指标做存活探测，配合 Actuator health 端点做深度检查。」

---

### 场景 S2：设备上报流量突增（W1 Day 3–4）

**业务背景：** 早上 8 点大量 IoT 设备同时上线，上报频率从 10 QPS 升到 150 QPS。

**操作：** 运行 `scripts/scenario-s2-device-burst.sh`，模拟 100 个 `device-{1..100}` 每 200ms 上报一次。

**监控面板：** Traffic 行 — QPS 折线、P50/P95/P99 延迟、成功请求占比。

**关键指标：**
```promql
# QPS
sum(rate(http_server_requests_seconds_count{uri="/api/v1/devices/{deviceId}/reports", method="POST"}[1m]))

# P99 延迟
histogram_quantile(0.99,
  sum(rate(http_server_requests_seconds_bucket{uri="/api/v1/devices/{deviceId}/reports"}[5m])) by (le)
)

# 成功率
1 - (
  sum(rate(http_server_requests_seconds_count{status=~"5.."}[5m]))
  / sum(rate(http_server_requests_seconds_count[5m]))
)
```

**预期曲线变化：**
1. QPS 从 ~0 阶跃到 100–200
2. P99 从 < 50ms 升到 50–150ms（仍健康）
3. 错误率保持 < 1%
4. HikariCP active connections 缓慢上升但 pending 保持 0

**面试话术：** 「流量突增时我先看 QPS 确认量级，再看 P99 是否劣化，最后看错误率判断是否已影响用户。」

---

### 场景 S3：应用异常错误飙升（W1 Day 5 / W2 Day 1）

**业务背景：** 新版本代码有 bug，或下游序列化失败，导致大量 500 错误。

**操作：** 运行 `scripts/scenario-s3-error-injection.sh`，50% 请求打 `POST /api/v1/debug/error`。

**监控面板：** Errors 行 — 5xx 计数、错误率百分比、按 status 分组的请求分布。

**关键指标：**
```promql
# 5xx 速率
sum(rate(http_server_requests_seconds_count{status=~"5.."}[1m]))

# 错误率
sum(rate(http_server_requests_seconds_count{status=~"5.."}[5m]))
/ sum(rate(http_server_requests_seconds_count[5m]))
```

**预期曲线变化：**
1. 错误率从 < 1% 飙升到 30%–50%
2. QPS 不变但「成功 QPS」下降
3. P99 可能下降（快速失败）或上升（异常处理耗时）—— 观察并记录

**面试话术：** 「错误率是比 QPS 更紧急的指标；QPS 高但错误率高意味着系统在『高效地失败』。」

---

### 场景 S4：数据库连接池压力（W2 Day 2–3）

**业务背景：** PostgreSQL 出现慢查询，连接被长时间占用，新请求排队等连接——雪崩的前兆。

**操作：**
1. 开启 debug 端点 `POST /api/v1/debug/slow-query?seconds=3`
2. 同时运行 S2 压测脚本

**监控面板：** Saturation 行 — HikariCP active/idle/pending、P99 延迟、PostgreSQL 相关（如有 exporter）。

**关键指标：**
```promql
hikaricp_connections_active{application="device-report-service"}
hikaricp_connections_pending{application="device-report-service"}
hikaricp_connections_max{application="device-report-service"}

histogram_quantile(0.99, sum(rate(http_server_requests_seconds_bucket[5m])) by (le))
```

**预期曲线变化：**
1. `hikaricp_connections_active` 接近 `max`（默认 10）
2. `hikaricp_connections_pending` 从 0 变为 > 0 ← **最关键信号**
3. P99 从 < 200ms 升到 > 3000ms
4. 错误率可能上升（连接超时）

**面试话术：** 「pending > 0 说明请求在等连接而非执行业务，这是数据库层饱和的直接信号，也是雪崩链路的早期环节。」

---

### 场景 S5：告警触发验证（W2 Day 4–5）

**业务背景：** 凌晨 3 点服务异常，需要告警自动通知值班人员。

**操作：** 依次触发 S3（错误率告警）和 S4（延迟/连接池告警），在 Prometheus/Grafana 确认告警状态变为 Firing。

**告警规则：**

```yaml
# infra/prometheus/alert-rules-device-report.yml
groups:
  - name: device-report-service
    rules:
      - alert: DeviceReportServiceDown
        expr: up{job="device-report-service"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "device-report-service 不可达"
          description: "Prometheus 无法抓取 device-report-service 超过 1 分钟"

      - alert: DeviceReportHighErrorRate
        expr: |
          sum(rate(http_server_requests_seconds_count{application="device-report-service", status=~"5.."}[5m]))
          / sum(rate(http_server_requests_seconds_count{application="device-report-service"}[5m]))
          > 0.05
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "设备上报服务错误率超过 5%"

      - alert: DeviceReportHighLatencyP99
        expr: |
          histogram_quantile(0.99,
            sum(rate(http_server_requests_seconds_bucket{application="device-report-service"}[5m])) by (le)
          ) > 0.5
        for: 3m
        labels:
          severity: warning
        annotations:
          summary: "设备上报服务 P99 延迟超过 500ms"

      - alert: DeviceReportConnectionPoolExhausted
        expr: hikaricp_connections_pending{application="device-report-service"} > 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "HikariCP 连接池出现等待队列"
```

**预期结果：**
- S3 触发 `DeviceReportHighErrorRate`
- S4 触发 `DeviceReportHighLatencyP99` 和 `DeviceReportConnectionPoolExhausted`
- 恢复后告警回到 Inactive（for 窗口过后）

---

### 场景 S6：APISIX 网关健康修复（W2 Day 5）

**业务背景：** 网关是 IoT 流量入口，unhealthy 意味着路由或上游探测异常。

**操作：** 排查 `apisix-home-iot` unhealthy 原因，配置上游指向 `device-report-service`，验证 APISIX Prometheus 指标出现在 Grafana。

**关键检查：**
```bash
curl -s http://localhost:9091/apisix/prometheus/metrics | head -20
curl -s http://localhost:9080/apisix/admin/routes -H "X-API-KEY: <your-admin-key>"
```

**监控：** 对比「网关 QPS」与「应用 QPS」是否一致（Phase 2 限流实验的前置条件）。

---

## W1 / W2 日程建议

| 天 | 场景 | 任务编号 | 时长 |
|----|------|---------|------|
| D1 | 环境准备 | Task 1–2 | 3h |
| D2 | S1 健康巡检 | Task 3–6 | 3h |
| D3 | S2 流量突增（编码） | Task 7–10 | 4h |
| D4 | S2 流量突增（Dashboard） | Task 11–13 | 3h |
| D5 | S3 错误注入 | Task 14–15 | 2h |
| D6 | 复盘 + 面试题 W1 | — | 2h |
| D7 | S4 连接池压力 | Task 16–17 | 3h |
| D8 | S5 告警配置 | Task 18–20 | 4h |
| D9 | S6 APISIX 修复 | Task 21 | 2h |
| D10 | 综合演练 + 面试题 W2 | Task 22 | 3h |

---

## Implementation Tasks

### Task 1: 初始化 PostgreSQL 数据库

**Files:**
- Create: `iot-learn-lab/infra/postgres/init-iot-learn.sql`

- [ ] **Step 1: 编写建库建表 SQL**

```sql
-- iot-learn-lab/infra/postgres/init-iot-learn.sql
CREATE DATABASE iot_learn;

\c iot_learn

CREATE TABLE IF NOT EXISTS device_report (
    id          BIGSERIAL PRIMARY KEY,
    device_id   VARCHAR(64)  NOT NULL,
    payload     JSONB        NOT NULL,
    reported_at TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_device_report_device_id ON device_report (device_id);
CREATE INDEX idx_device_report_reported_at ON device_report (reported_at DESC);

COMMENT ON TABLE device_report IS 'IoT 设备遥测上报记录（Phase 1 实验表）';
```

- [ ] **Step 2: 在 postgres-alpine 容器中执行**

```bash
# WSL 中执行
docker exec -i postgres-alpine psql -U postgres < iot-learn-lab/infra/postgres/init-iot-learn.sql
```

Expected: `CREATE DATABASE`, `CREATE TABLE`, `CREATE INDEX` 无报错。

- [ ] **Step 3: 验证表存在**

```bash
docker exec -it postgres-alpine psql -U postgres -d iot_learn -c "\dt"
```

Expected: 列出 `device_report` 表。

- [ ] **Step 4: Commit**

```bash
git add iot-learn-lab/infra/postgres/init-iot-learn.sql
git commit -m "feat(phase1): add PostgreSQL schema for device_report"
```

---

### Task 2: 创建 Maven 多模块项目骨架（已完成）

**Files:**
- Create: `iot-learn-lab/pom.xml`（父 POM，`packaging=pom`，Java 21）
- Create: `iot-learn-lab/device-report-service/pom.xml`（子模块，继承父 POM）
- Create: `iot-learn-lab/device-report-service/src/main/java/com/iot/learn/devicereport/DeviceReportApplication.java`
- Create: `iot-learn-lab/device-report-service/src/main/resources/application.yml`
- Create: 包目录占位：`controller/`, `service/`, `repository/`, `entity/`, `dto/`
- Create: `iot-learn-lab/infra/`, `iot-learn-lab/scripts/` 目录占位

- [x] **Step 1: 创建父 POM `iot-learn-lab/pom.xml`**

父 POM 继承 `spring-boot-starter-parent`，声明 `<modules>` 和 `java.version=21`。详见仓库内实际文件。

- [x] **Step 2: 创建子模块 POM `device-report-service/pom.xml`**

子模块 `<parent>` 指向 `com.iot.learn:iot-learn-lab:0.1.0-SNAPSHOT`，声明 Web/JPA/Actuator/Prometheus 等依赖。

- [x] **Step 3: 创建 application.yml 与启动类**

- [x] **Step 4: 验证项目编译（在父工程根目录执行）**

```bash
cd iot-learn-lab
mvn -q clean verify
```

Expected: `BUILD SUCCESS`

- [x] **Step 5: Commit**

```bash
git add iot-learn-lab/
git commit -m "feat(phase1): scaffold iot-learn-lab parent pom and device-report-service module"
```

---

### Task 2（历史参考）: 单模块 pom 示例 — 已废弃，改用父/子多模块结构

以下为旧版单模块 pom 参考，**勿再使用**：

```xml
<!-- 已废弃：device-report-service 不再直接继承 spring-boot-starter-parent -->
<java.version>21</java.version>
```

---

### Task 3: 设备上报领域模型与 Repository

**Files:**
- Create: `iot-learn-lab/device-report-service/src/main/java/com/iot/learn/devicereport/entity/DeviceReport.java`
- Create: `iot-learn-lab/device-report-service/src/main/java/com/iot/learn/devicereport/dto/DeviceReportRequest.java`
- Create: `iot-learn-lab/device-report-service/src/main/java/com/iot/learn/devicereport/dto/DeviceReportResponse.java`
- Create: `iot-learn-lab/device-report-service/src/main/java/com/iot/learn/devicereport/repository/DeviceReportRepository.java`

- [ ] **Step 1: 创建 Entity**

```java
package com.iot.learn.devicereport.entity;

import jakarta.persistence.*;
import org.hibernate.annotations.JdbcTypeCode;
import org.hibernate.type.SqlTypes;

import java.time.Instant;
import java.util.Map;

@Entity
@Table(name = "device_report")
public class DeviceReport {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "device_id", nullable = false, length = 64)
    private String deviceId;

    @JdbcTypeCode(SqlTypes.JSON)
    @Column(nullable = false, columnDefinition = "jsonb")
    private Map<String, Object> payload;

    @Column(name = "reported_at", nullable = false)
    private Instant reportedAt;

    public Long getId() { return id; }
    public void setId(Long id) { this.id = id; }
    public String getDeviceId() { return deviceId; }
    public void setDeviceId(String deviceId) { this.deviceId = deviceId; }
    public Map<String, Object> getPayload() { return payload; }
    public void setPayload(Map<String, Object> payload) { this.payload = payload; }
    public Instant getReportedAt() { return reportedAt; }
    public void setReportedAt(Instant reportedAt) { this.reportedAt = reportedAt; }
}
```

- [ ] **Step 2: 创建 DTO**

```java
package com.iot.learn.devicereport.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import java.util.Map;

public class DeviceReportRequest {

    @NotNull
    private Map<String, Object> payload;

    public Map<String, Object> getPayload() { return payload; }
    public void setPayload(Map<String, Object> payload) { this.payload = payload; }
}
```

```java
package com.iot.learn.devicereport.dto;

import java.time.Instant;

public class DeviceReportResponse {
    private Long id;
    private String deviceId;
    private Instant reportedAt;

    public DeviceReportResponse(Long id, String deviceId, Instant reportedAt) {
        this.id = id;
        this.deviceId = deviceId;
        this.reportedAt = reportedAt;
    }

    public Long getId() { return id; }
    public String getDeviceId() { return deviceId; }
    public Instant getReportedAt() { return reportedAt; }
}
```

- [ ] **Step 3: 创建 Repository**

```java
package com.iot.learn.devicereport.repository;

import com.iot.learn.devicereport.entity.DeviceReport;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

public interface DeviceReportRepository extends JpaRepository<DeviceReport, Long> {

    @Query(value = "SELECT pg_sleep(CAST(:seconds AS double precision)) IS NOT NULL", nativeQuery = true)
    void sleepSeconds(@Param("seconds") double seconds);
}
```

- [ ] **Step 4: Commit**

```bash
git add iot-learn-lab/device-report-service/src/main/java/com/iot/learn/devicereport/
git commit -m "feat(phase1): add device report entity, dto, and repository"
```

---

### Task 4: 设备上报 Service（TDD）

**Files:**
- Create: `iot-learn-lab/device-report-service/src/test/java/com/iot/learn/devicereport/service/DeviceReportServiceTest.java`
- Create: `iot-learn-lab/device-report-service/src/main/java/com/iot/learn/devicereport/service/DeviceReportService.java`

- [ ] **Step 1: 编写失败测试**

```java
package com.iot.learn.devicereport.service;

import com.iot.learn.devicereport.dto.DeviceReportRequest;
import com.iot.learn.devicereport.dto.DeviceReportResponse;
import com.iot.learn.devicereport.entity.DeviceReport;
import com.iot.learn.devicereport.repository.DeviceReportRepository;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.util.Map;
import java.time.Instant;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class DeviceReportServiceTest {

    @Mock
    private DeviceReportRepository repository;

    @InjectMocks
    private DeviceReportService service;

    @Test
    void saveReport_persistsDeviceIdAndPayload() {
        DeviceReportRequest request = new DeviceReportRequest();
        request.setPayload(Map.of("temperature", 25.5, "humidity", 60));

        DeviceReport saved = new DeviceReport();
        saved.setId(1L);
        saved.setDeviceId("device-001");
        saved.setPayload(request.getPayload());
        saved.setReportedAt(Instant.parse("2026-07-02T08:00:00Z"));

        when(repository.save(any(DeviceReport.class))).thenReturn(saved);

        DeviceReportResponse response = service.saveReport("device-001", request);

        ArgumentCaptor<DeviceReport> captor = ArgumentCaptor.forClass(DeviceReport.class);
        verify(repository).save(captor.capture());

        assertThat(captor.getValue().getDeviceId()).isEqualTo("device-001");
        assertThat(captor.getValue().getPayload()).containsEntry("temperature", 25.5);
        assertThat(response.getId()).isEqualTo(1L);
        assertThat(response.getDeviceId()).isEqualTo("device-001");
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd iot-learn-lab
mvn -q test -Dtest=DeviceReportServiceTest
```

Expected: FAIL — `DeviceReportService` 类不存在。

- [ ] **Step 3: 实现 Service**

```java
package com.iot.learn.devicereport.service;

import com.iot.learn.devicereport.dto.DeviceReportRequest;
import com.iot.learn.devicereport.dto.DeviceReportResponse;
import com.iot.learn.devicereport.entity.DeviceReport;
import com.iot.learn.devicereport.repository.DeviceReportRepository;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;

@Service
public class DeviceReportService {

    private final DeviceReportRepository repository;

    public DeviceReportService(DeviceReportRepository repository) {
        this.repository = repository;
    }

    @Transactional
    public DeviceReportResponse saveReport(String deviceId, DeviceReportRequest request) {
        DeviceReport report = new DeviceReport();
        report.setDeviceId(deviceId);
        report.setPayload(request.getPayload());
        report.setReportedAt(Instant.now());

        DeviceReport saved = repository.save(report);
        return new DeviceReportResponse(saved.getId(), saved.getDeviceId(), saved.getReportedAt());
    }

    @Transactional
    public void simulateSlowQuery(double seconds) {
        repository.sleepSeconds(seconds);
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

```bash
mvn -q test -Dtest=DeviceReportServiceTest
```

Expected: `BUILD SUCCESS`, 1 test passed.

- [ ] **Step 5: Commit**

```bash
git add iot-learn-lab/device-report-service/src/main/java/com/iot/learn/devicereport/service/
git add iot-learn-lab/device-report-service/src/test/java/com/iot/learn/devicereport/service/
git commit -m "feat(phase1): add DeviceReportService with unit test"
```

---

### Task 5: 设备上报 API Controller（TDD）

**Files:**
- Create: `iot-learn-lab/device-report-service/src/test/java/com/iot/learn/devicereport/controller/DeviceReportControllerTest.java`
- Create: `iot-learn-lab/device-report-service/src/main/java/com/iot/learn/devicereport/controller/DeviceReportController.java`

- [ ] **Step 1: 编写 Controller 测试**

```java
package com.iot.learn.devicereport.controller;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.iot.learn.devicereport.dto.DeviceReportRequest;
import com.iot.learn.devicereport.dto.DeviceReportResponse;
import com.iot.learn.devicereport.service.DeviceReportService;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;

import java.time.Instant;
import java.util.Map;

import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@WebMvcTest(DeviceReportController.class)
class DeviceReportControllerTest {

    @Autowired
    private MockMvc mockMvc;

    @Autowired
    private ObjectMapper objectMapper;

    @MockBean
    private DeviceReportService service;

    @Test
    void postReport_returns201() throws Exception {
        DeviceReportRequest request = new DeviceReportRequest();
        request.setPayload(Map.of("temperature", 25.5));

        when(service.saveReport(eq("device-001"), org.mockito.ArgumentMatchers.any()))
            .thenReturn(new DeviceReportResponse(1L, "device-001", Instant.parse("2026-07-02T08:00:00Z")));

        mockMvc.perform(post("/api/v1/devices/device-001/reports")
                .contentType(MediaType.APPLICATION_JSON)
                .content(objectMapper.writeValueAsString(request)))
            .andExpect(status().isCreated())
            .andExpect(jsonPath("$.id").value(1))
            .andExpect(jsonPath("$.deviceId").value("device-001"));
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
mvn -q test -Dtest=DeviceReportControllerTest
```

Expected: FAIL — `DeviceReportController` 不存在。

- [ ] **Step 3: 实现 Controller**

```java
package com.iot.learn.devicereport.controller;

import com.iot.learn.devicereport.dto.DeviceReportRequest;
import com.iot.learn.devicereport.dto.DeviceReportResponse;
import com.iot.learn.devicereport.service.DeviceReportService;
import jakarta.validation.Valid;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/v1/devices/{deviceId}/reports")
public class DeviceReportController {

    private final DeviceReportService service;

    public DeviceReportController(DeviceReportService service) {
        this.service = service;
    }

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    public DeviceReportResponse postReport(
            @PathVariable String deviceId,
            @Valid @RequestBody DeviceReportRequest request) {
        return service.saveReport(deviceId, request);
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

```bash
mvn -q test -Dtest=DeviceReportControllerTest
```

Expected: `BUILD SUCCESS`

- [ ] **Step 5: Commit**

```bash
git add iot-learn-lab/device-report-service/src/main/java/com/iot/learn/devicereport/controller/
git add iot-learn-lab/device-report-service/src/test/java/com/iot/learn/devicereport/controller/
git commit -m "feat(phase1): add device report REST API endpoint"
```

---

### Task 6: 故障注入 Debug 端点（场景 S3/S4）

**Files:**
- Create: `iot-learn-lab/device-report-service/src/main/java/com/iot/learn/devicereport/controller/DebugController.java`

- [ ] **Step 1: 实现 DebugController**

```java
package com.iot.learn.devicereport.controller;

import com.iot.learn.devicereport.service.DeviceReportService;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.server.ResponseStatusException;

@RestController
@RequestMapping("/api/v1/debug")
public class DebugController {

    private final DeviceReportService service;

    public DebugController(DeviceReportService service) {
        this.service = service;
    }

    @PostMapping("/error")
    public void triggerError() {
        throw new ResponseStatusException(HttpStatus.INTERNAL_SERVER_ERROR, "Simulated error for observability lab");
    }

    @PostMapping("/slow-query")
    public void triggerSlowQuery(@RequestParam(defaultValue = "3") double seconds) {
        if (seconds < 0 || seconds > 30) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, "seconds must be 0-30");
        }
        service.simulateSlowQuery(seconds);
    }
}
```

- [ ] **Step 2: 本地启动并手动验证 S1**

```bash
cd iot-learn-lab
mvn spring-boot:run -pl device-report-service
```

另开终端：

```bash
curl -s http://localhost:8765/actuator/health | jq .
curl -s -X POST http://localhost:8765/api/v1/devices/device-001/reports \
  -H "Content-Type: application/json" \
  -d '{"payload":{"temperature":25.5,"humidity":60}}' | jq .
curl -s http://localhost:8765/actuator/prometheus | grep http_server_requests_seconds_count | head -5
```

Expected:
- health status `UP`
- POST 返回 `{"id":1,"deviceId":"device-001","reportedAt":"..."}`
- prometheus 端点含 `http_server_requests_seconds_count` 行

- [ ] **Step 3: Commit**

```bash
git add iot-learn-lab/device-report-service/src/main/java/com/iot/learn/devicereport/controller/DebugController.java
git commit -m "feat(phase1): add debug endpoints for error and slow-query scenarios"
```

---

### Task 7: 配置 Prometheus 抓取

**Files:**
- Create: `iot-learn-lab/infra/prometheus/scrape-device-report.yml`

- [ ] **Step 1: 编写 scrape job 配置片段**

```yaml
# 追加到 prometheus-learn 的 prometheus.yml 的 scrape_configs 末尾
- job_name: device-report-service
  metrics_path: /actuator/prometheus
  static_configs:
    - targets:
        - host.docker.internal:8765
      labels:
        env: learn
        service: device-report-service
```

> **WSL Docker 说明：** Prometheus 容器内访问宿主机 Spring Boot 用 `host.docker.internal:8765`。若不通，改用宿主机 WSL IP（`ip addr show eth0`）或 `172.17.0.1:8765`。

- [ ] **Step 2: 合并到 prometheus-learn 并热加载**

```bash
# 找到 prometheus 配置文件挂载路径后合并，然后：
docker exec prometheus-learn kill -HUP 1
```

- [ ] **Step 3: 验证 Target 状态**

浏览器打开 `http://localhost:9090/targets`

Expected: `device-report-service` 状态 **UP**。

- [ ] **Step 4: 在 Prometheus 执行 S1 查询**

```promql
up{job="device-report-service"}
```

Expected: 返回值 `1`。

- [ ] **Step 5: Commit**

```bash
git add iot-learn-lab/infra/prometheus/
git commit -m "feat(phase1): add Prometheus scrape config for device-report-service"
```

---

### Task 8: 场景压测脚本 S2

**Files:**
- Create: `iot-learn-lab/scripts/scenario-s2-device-burst.sh`

- [ ] **Step 1: 编写压测脚本**

```bash
#!/usr/bin/env bash
# iot-learn-lab/scripts/scenario-s2-device-burst.sh
# 场景 S2：模拟 100 设备持续上报 60 秒
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8765}"
DURATION="${DURATION:-60}"

echo "=== S2 设备上报流量突增 ==="
echo "目标: $BASE_URL, 持续: ${DURATION}s"

end=$((SECONDS + DURATION))
while [ $SECONDS -lt $end ]; do
  for i in $(seq 1 100); do
    curl -s -o /dev/null -X POST "$BASE_URL/api/v1/devices/device-$i/reports" \
      -H "Content-Type: application/json" \
      -d "{\"payload\":{\"temperature\":$((20 + RANDOM % 15)),\"seq\":$SECONDS}}" &
  done
  wait
  sleep 0.2
done

echo "=== S2 完成，请在 Grafana 查看 QPS 与 P99 ==="
```

- [ ] **Step 2: 赋予执行权限并运行**

```bash
chmod +x iot-learn-lab/scripts/scenario-s2-device-burst.sh
./iot-learn-lab/scripts/scenario-s2-device-burst.sh
```

- [ ] **Step 3: 在 Prometheus 验证 S2 指标**

```promql
sum(rate(http_server_requests_seconds_count{uri="/api/v1/devices/{deviceId}/reports"}[1m]))
```

Expected: 值在 50–200 范围（取决于机器性能）。

- [ ] **Step 4: Commit**

```bash
git add iot-learn-lab/scripts/scenario-s2-device-burst.sh
git commit -m "feat(phase1): add S2 device burst load test script"
```

---

### Task 9: 场景脚本 S3 / S4

**Files:**
- Create: `iot-learn-lab/scripts/scenario-s3-error-injection.sh`
- Create: `iot-learn-lab/scripts/scenario-s4-db-pressure.sh`

- [ ] **Step 1: 编写 S3 错误注入脚本**

```bash
#!/usr/bin/env bash
# iot-learn-lab/scripts/scenario-s3-error-injection.sh
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8765}"
DURATION="${DURATION:-120}"

echo "=== S3 应用异常错误飙升 ==="
end=$((SECONDS + DURATION))
while [ $SECONDS -lt $end ]; do
  # 50% 正常请求
  curl -s -o /dev/null -X POST "$BASE_URL/api/v1/devices/device-err/reports" \
    -H "Content-Type: application/json" \
    -d '{"payload":{"temperature":25}}' &
  # 50% 错误请求
  curl -s -o /dev/null -X POST "$BASE_URL/api/v1/debug/error" &
  wait
  sleep 0.1
done
echo "=== S3 完成，检查错误率是否 > 5% ==="
```

- [ ] **Step 2: 编写 S4 数据库压力脚本**

```bash
#!/usr/bin/env bash
# iot-learn-lab/scripts/scenario-s4-db-pressure.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_URL="${BASE_URL:-http://localhost:8765}"

echo "=== S4 数据库连接池压力 ==="
echo "先启动 10 个慢查询（每个占连接 5 秒）..."

for _ in $(seq 1 10); do
  curl -s -o /dev/null -X POST "$BASE_URL/api/v1/debug/slow-query?seconds=5" &
done

sleep 2
echo "慢查询已占用连接池，现在叠加正常流量..."
DURATION=60 BASE_URL="$BASE_URL" "$SCRIPT_DIR/scenario-s2-device-burst.sh"

echo "=== S4 完成，检查 hikaricp_connections_pending 是否 > 0 ==="
```

- [ ] **Step 3: 赋予权限**

```bash
chmod +x iot-learn-lab/scripts/scenario-s3-error-injection.sh
chmod +x iot-learn-lab/scripts/scenario-s4-db-pressure.sh
```

- [ ] **Step 4: Commit**

```bash
git add iot-learn-lab/scripts/
git commit -m "feat(phase1): add S3 error injection and S4 db pressure scripts"
```

---

### Task 10: Grafana Dashboard

**Files:**
- Create: `iot-learn-lab/infra/grafana/dashboards/device-report-observability.json`
- Create: `iot-learn-lab/infra/grafana/provisioning/datasources/prometheus.yml`
- Create: `iot-learn-lab/infra/grafana/provisioning/dashboards/default.yml`

- [ ] **Step 1: 配置 Grafana 数据源 provisioning**

```yaml
# iot-learn-lab/infra/grafana/provisioning/datasources/prometheus.yml
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus-learn:9090
    isDefault: true
    editable: false
```

- [ ] **Step 2: 配置 Dashboard provisioning**

```yaml
# iot-learn-lab/infra/grafana/provisioning/dashboards/default.yml
apiVersion: 1
providers:
  - name: iot-learn
    orgId: 1
    folder: IoT Learn
    type: file
    disableDeletion: false
    options:
      path: /var/lib/grafana/dashboards
```

- [ ] **Step 3: 在 Grafana UI 手动创建 Dashboard（推荐学习方式）**

打开 `http://localhost:3000`，新建 Dashboard `Device Report Observability`，按以下 4 行布局添加 Panel：

**Row 1 — Overview（场景 S1）**

| Panel 名 | 类型 | PromQL |
|---------|------|--------|
| Service UP | Stat | `up{job="device-report-service"}` |
| JVM Heap Used | Gauge | `jvm_memory_used_bytes{area="heap",application="device-report-service"} / jvm_memory_max_bytes{area="heap",application="device-report-service"}` |
| Live Threads | Stat | `jvm_threads_live_threads{application="device-report-service"}` |

**Row 2 — Traffic（场景 S2）**

| Panel 名 | 类型 | PromQL |
|---------|------|--------|
| Request Rate (QPS) | Time series | `sum(rate(http_server_requests_seconds_count{application="device-report-service"}[1m]))` |
| P50 / P95 / P99 Latency | Time series | 三条查询：`histogram_quantile(0.50/0.95/0.99, sum(rate(http_server_requests_seconds_bucket{application="device-report-service"}[5m])) by (le))` |
| Success Rate | Gauge | `1 - (sum(rate(http_server_requests_seconds_count{application="device-report-service",status=~"5.."}[5m])) / sum(rate(http_server_requests_seconds_count{application="device-report-service"}[5m])))` |

**Row 3 — Errors（场景 S3）**

| Panel 名 | 类型 | PromQL |
|---------|------|--------|
| 5xx Rate | Time series | `sum(rate(http_server_requests_seconds_count{application="device-report-service",status=~"5.."}[1m]))` |
| Error Ratio | Time series | `sum(rate(http_server_requests_seconds_count{application="device-report-service",status=~"5.."}[5m])) / sum(rate(http_server_requests_seconds_count{application="device-report-service"}[5m]))` |
| Requests by Status | Bar chart | `sum by (status) (increase(http_server_requests_seconds_count{application="device-report-service"}[5m]))` |

**Row 4 — Saturation（场景 S4）**

| Panel 名 | 类型 | PromQL |
|---------|------|--------|
| HikariCP Active | Time series | `hikaricp_connections_active{application="device-report-service"}` |
| HikariCP Pending | Time series | `hikaricp_connections_pending{application="device-report-service"}` |
| Pool Usage % | Gauge | `hikaricp_connections_active{application="device-report-service"} / hikaricp_connections_max{application="device-report-service"}` |

- [ ] **Step 4: 运行 S2 并截图 Dashboard**

```bash
./iot-learn-lab/scripts/scenario-s2-device-burst.sh
```

Expected: QPS 曲线上升，P99 < 200ms，Success Rate > 99%。

- [ ] **Step 5: 导出 Dashboard JSON 保存到仓库**

Grafana → Dashboard settings → JSON Model → 复制保存到 `iot-learn-lab/infra/grafana/dashboards/device-report-observability.json`

- [ ] **Step 6: Commit**

```bash
git add iot-learn-lab/infra/grafana/
git commit -m "feat(phase1): add Grafana dashboard for device-report observability"
```

---

### Task 11: Prometheus 告警规则（场景 S5）

**Files:**
- Create: `iot-learn-lab/infra/prometheus/alert-rules-device-report.yml`

- [ ] **Step 1: 创建告警规则文件**

内容见本文「场景 S5」章节的 `alert-rules-device-report.yml` 完整 YAML。

- [ ] **Step 2: 合并到 Prometheus 配置**

在 `prometheus.yml` 添加：

```yaml
rule_files:
  - /etc/prometheus/alert-rules-device-report.yml
```

挂载文件并 reload：

```bash
docker exec prometheus-learn kill -HUP 1
```

- [ ] **Step 3: 验证规则已加载**

打开 `http://localhost:9090/rules`

Expected: 显示 4 条 `device-report-service` 规则，状态 Inactive。

- [ ] **Step 4: 运行 S3 触发错误率告警**

```bash
./iot-learn-lab/scripts/scenario-s3-error-injection.sh
```

等待 2 分钟后刷新 `http://localhost:9090/alerts`

Expected: `DeviceReportHighErrorRate` 状态 **Firing**。

- [ ] **Step 5: 运行 S4 触发连接池告警**

```bash
./iot-learn-lab/scripts/scenario-s4-db-pressure.sh
```

Expected: `DeviceReportConnectionPoolExhausted` 和 `DeviceReportHighLatencyP99` Firing。

- [ ] **Step 6: Commit**

```bash
git add iot-learn-lab/infra/prometheus/alert-rules-device-report.yml
git commit -m "feat(phase1): add Prometheus alert rules for device-report-service"
```

---

### Task 12: APISIX 健康修复（场景 S6）

**Files:**
- Modify: APISIX 路由配置（通过 Admin API 或现有配置文件）

- [ ] **Step 1: 检查 APISIX 不健康原因**

```bash
docker inspect apisix-home-iot --format '{{json .State.Health}}' | jq .
docker logs apisix-home-iot --tail 50
curl -s http://localhost:9080/apisix/status
```

- [ ] **Step 2: 确认 Prometheus 插件端口**

```bash
curl -s http://localhost:9091/apisix/prometheus/metrics | head -5
```

Expected: 返回 Prometheus 格式指标。

- [ ] **Step 3: 创建上游和路由（Admin API 示例）**

```bash
# 将 <ADMIN_KEY> 替换为你的 APISIX Admin API Key
ADMIN="http://localhost:9180/apisix/admin"
KEY="<ADMIN_KEY>"

curl -s -X PUT "$ADMIN/upstreams/1" -H "X-API-KEY: $KEY" -H "Content-Type: application/json" -d '{
  "name": "device-report-upstream",
  "type": "roundrobin",
  "nodes": {"host.docker.internal:8765": 1},
  "checks": {
    "active": {
      "http_path": "/actuator/health",
      "healthy": {"interval": 2, "successes": 1},
      "unhealthy": {"interval": 1, "http_failures": 2}
    }
  }
}'

curl -s -X PUT "$ADMIN/routes/1" -H "X-API-KEY: $KEY" -H "Content-Type: application/json" -d '{
  "uri": "/api/v1/devices/*/reports",
  "methods": ["POST"],
  "upstream_id": 1
}'
```

- [ ] **Step 4: 通过网关验证上报**

```bash
curl -s -X POST http://localhost:9080/api/v1/devices/device-via-apisix/reports \
  -H "Content-Type: application/json" \
  -d '{"payload":{"temperature":30}}' | jq .
```

Expected: 201 响应，与直连 8765 一致。

- [ ] **Step 5: 将 APISIX 加入 Prometheus scrape（可选）**

```yaml
- job_name: apisix
  static_configs:
    - targets: ['apisix-home-iot:9091']
```

- [ ] **Step 6: 确认容器健康**

```bash
docker ps --filter name=apisix-home-iot --format "{{.Status}}"
```

Expected: 含 `(healthy)`。

---

### Task 13: Phase 1 综合演练与复盘文档

**Files:**
- Create: `iot-learn-lab/docs/phase1-retrospective.md`

- [ ] **Step 1: 按顺序运行全部场景并记录**

```bash
# 确保 device-report-service 运行中
./iot-learn-lab/scripts/scenario-s2-device-burst.sh
./iot-learn-lab/scripts/scenario-s3-error-injection.sh
./iot-learn-lab/scripts/scenario-s4-db-pressure.sh
```

- [ ] **Step 2: 填写复盘模板**

```markdown
# Phase 1 复盘

## 场景执行记录

| 场景 | 执行时间 | 关键指标变化 | 截图路径 |
|------|---------|-------------|---------|
| S1 健康巡检 | | up=1 | |
| S2 流量突增 | | QPS=__, P99=__ms | |
| S3 错误飙升 | | 错误率=__% | |
| S4 连接池压力 | | pending=__ | |
| S5 告警触发 | | 触发了哪些 alert | |
| S6 APISIX | | 网关健康状态 | |

## 面试题自答

1. P99 和平均延迟的区别？为什么看 P99？
2. 错误率和高 QPS 哪个更紧急？为什么？
3. hikaricp_connections_pending > 0 意味着什么？
4. SLI 和 SLO 的区别？本实验的 SLO 是什么？
5. 告警太多怎么办？（抑制、分组、分级）
```

- [ ] **Step 3: Commit**

```bash
git add iot-learn-lab/docs/phase1-retrospective.md
git commit -m "docs(phase1): add retrospective template and scenario checklist"
```

---

## Spec 覆盖自检

| Spec 要求 | 对应 Task / 场景 |
|-----------|-----------------|
| W1: micrometer + prometheus | Task 2, 6, 7 |
| W1: Grafana Dashboard QPS/P99/JVM/错误率 | Task 10, 场景 S1–S3 |
| W1: PostgreSQL 存储设备上报 | Task 1, 3–5 |
| W2: 告警规则 错误率>5%、P99>500ms | Task 11, 场景 S5 |
| W2: HikariCP 连接池指标 | Task 10 Row 4, 场景 S4 |
| W2: 修复 APISIX unhealthy | Task 12, 场景 S6 |
| Dashboard 含 HikariCP | Task 10 Row 4 |

无遗漏。

---

## Phase 1 完成标准（Checklist）

- [ ] `device-report-service` 启动，`/actuator/prometheus` 可访问
- [ ] Prometheus Target `device-report-service` 为 UP
- [ ] Grafana Dashboard 4 行 Panel 全部有数据
- [ ] 场景 S1–S6 各执行一次并截图
- [ ] 4 条告警规则加载，S3/S4 能触发 Firing
- [ ] APISIX 容器状态 healthy，网关可转发上报请求
- [ ] `phase1-retrospective.md` 填写完成
