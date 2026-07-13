# Phase 5 综合演练 + 面试冲刺 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 串联 Phase 1–4 全部能力，完成 **W9 Kafka 异步削峰 + Redis 缓存三高（穿透/击穿/雪崩）** 实验，并在 **W10 终极演练** 中一次性走通「流量突增 → 网关限流 → 下游故障 → Sentinel 熔断降级 → 金丝雀缺陷 → 回滚」完整故事线，输出可背诵的 **IoT 高可用架构面试稿**。

**Architecture:** 设备上报经 APISIX 进入 `device-report-service`；**同步路径** 直写 PostgreSQL（易打满 HikariCP）；**异步路径** 写 Kafka Topic → `device-report-consumer` 批量落库。Redis 除 Phase 3 的 dispatch 降级外，新增 **设备统计读缓存**。Prometheus/Grafana 新增 **Kafka + Consumer + Cache** 行；W10 脚本按时间线切换 APISIX 插件、Sentinel 状态、金丝雀权重与 v2 bug 开关。

**Tech Stack:** Java 21, Spring Boot 3.3.5, Spring Kafka 3.x, Kafka 3.9（KRaft 单节点）, Redis 7, PostgreSQL 16, 复用 Phase 1–4 全部组件

**Spec 来源:** `docs/superpowers/specs/2026-07-02-ops-learning-plan-design.md`（Phase 5 / W9–W10）

**前置条件（Phase 1–4 已完成）:**

- [x] Prometheus / Grafana / APISIX / Nacos / Redis / PostgreSQL 可用
- [x] `device-report-service` v1 `:8765`、`command-dispatch-service` `:8767` 正常
- [x] Phase 3 R1–R6、Phase 4 C1–C4 已跑通并填写 interview notes
- [x] 金丝雀脚本与 `bootstrap-canary-*.sh` 可用
- [ ] Phase 4 `phase4-interview-notes.md` 三道题已自测

**时间预算:** 2 周 × 10–15h = 20–30h

**与前期边界:**

| 阶段 | 本阶段做 | 本阶段不做 |
|------|----------|------------|
| Phase 3 | W10 串联熔断降级 | 不重复 R4/R5 单独教学 |
| Phase 4 | W10 串联金丝雀回滚 | 不重复 C2 分流教学 |
| Phase 5 | Kafka 削峰、缓存三高、终极演练 | **不上生产 K8s**（仅概念预习文档） |

---

## WSL2 + Windows 网络拓扑（Phase 5 扩展）

| 调用方 | 目标 | 地址 |
|--------|------|------|
| WSL 压测 / APISIX | device-report 同步/异步 | `localhost:9080` → `192.168.16.1:8765` |
| device-report（Producer） | Kafka Broker | `192.168.19.64:9092` |
| device-report-consumer | Kafka + PostgreSQL | `:8768`（Windows IDEA），连 WSL Kafka/PG |
| Prometheus | 抓取 producer + consumer | `8765`、`8768` |
| Kafka（可选 JMX/exporter） | 监控 lag | `192.168.19.64:9308` 或 Spring Micrometer |

```
┌─ Windows ───────────────────────────────────────────────────────────┐
│  device-report :8765  ──produce──→  Kafka :9092 (WSL)              │
│       │ sync ──→ PostgreSQL                                         │
│  device-report-consumer :8768  ←──consume──  batch INSERT → PG     │
│  command-dispatch :8767  ←── Feign（W10 故障注入）                   │
└─────────────────────────────────────────────────────────────────────┘
         ↑ APISIX :9080（W10 限流 / 金丝雀权重）
┌─ WSL ──┴─ Kafka / Redis / PG / Nacos / Prometheus / Grafana ────────┘
```

> **记忆口诀：** 削峰 = **先接请求、后慢慢写库**；W10 = **按剧本切换每一层防护**，而不是同时开所有插件。

---

## 文件结构（本阶段新增/修改）

```
iot-learn-lab/
├── device-report-service/
│   ├── pom.xml                              # + spring-kafka
│   ├── src/main/java/.../
│   │   ├── messaging/DeviceReportProducer.java
│   │   ├── controller/DeviceReportAsyncController.java
│   │   ├── controller/DeviceStatsController.java   # 缓存读场景
│   │   ├── service/DeviceStatsCacheService.java
│   │   └── config/KafkaProducerConfig.java
│   └── src/main/resources/
│       └── application-kafka.yml              # 可选 profile
├── device-report-consumer/                    # 新模块
│   ├── pom.xml
│   └── src/main/java/.../
│       ├── DeviceReportConsumerApplication.java
│       ├── listener/DeviceReportBatchListener.java
│       └── service/DeviceReportBatchWriter.java
├── infra/
│   ├── kafka/
│   │   ├── docker-compose-kafka.yml
│   │   ├── create-topics.sh
│   │   └── README-kafka.md
│   ├── prometheus/
│   │   └── scrape-device-report-consumer.yml
│   └── grafana/dashboards/
│       └── device-report-observability.json   # + Kafka/Cache/Capstone 行
├── scripts/phase5/
│   ├── scenario-e1-sync-10x-burst.sh
│   ├── scenario-e2-async-10x-burst.sh
│   ├── scenario-e3-kafka-lag-observe.sh
│   ├── scenario-e4-cache-penetration.sh
│   ├── scenario-e5-cache-breakdown.sh
│   ├── scenario-e6-cache-avalanche.sh
│   └── scenario-f1-ultimate-drill.sh
└── docs/
    ├── phase5-async-cache-runbook.md
    ├── phase5-ultimate-drill-runbook.md
    ├── phase5-interview-notes.md
    └── phase5-k8s-concepts-preview.md
```

**环境变量（WSL 脚本）：**

```bash
export GATEWAY_URL="${GATEWAY_URL:-http://localhost:9080}"
export DIRECT_URL="${DIRECT_URL:-http://192.168.16.1:8765}"
export CONSUMER_URL="${CONSUMER_URL:-http://192.168.16.1:8768}"
export KAFKA_BOOTSTRAP="${KAFKA_BOOTSTRAP:-192.168.19.64:9092}"
export KAFKA_TOPIC="${KAFKA_TOPIC:-device-report-events}"
export REDIS_HOST="${REDIS_HOST:-192.168.19.64}"
export BURST_MULTIPLIER="${BURST_MULTIPLIER:-10}"   # 10x 压测倍率
```

---

## 学习场景编排（Phase 5 概览）

> **原则：** 本节仅 **一句话预期**；每个场景的 **操作步骤、PromQL、对比截图** 分散在各 Task 的 **「验收与观测」** 及 `phase5-*-runbook.md`（Task 11–12 产出）。

| 场景 | 业务背景 | 一句话预期 | 对应 Task |
|------|----------|------------|-----------|
| **E1** 同步 10x 突增 | 峰值全打 DB | HikariCP pending 升、P99 恶化、部分 5xx/超时 | Task 4–5 |
| **E2** 异步 10x 突增 | 削峰填谷 | API **202 快速返回**；lag 可升但 API P99 低 | Task 2–5 |
| **E3** Kafka lag 消化 | 消费追平 | lag 先升后降；PG 写入速率与 consumer 批次一致 | Task 3–5 |
| **E4** 缓存穿透 | 恶意查不存在 deviceId | 无缓存时 DB QPS 高；**空值缓存** 后 DB 压力降 | Task 6–7 |
| **E5** 缓存击穿 | 热点 key 过期瞬间 | 并发打到 DB；**互斥锁/逻辑过期** 后 DB 尖峰消失 | Task 6–7 |
| **E6** 缓存雪崩 | 大量 key 同时过期 | DB 抖动；**随机 TTL** 后过期分散 | Task 6–7 |
| **F1** 终极演练 | 综合故障 | 按剧本走完 L2→L3→L4 全链路 | Task 9–12 |

**推荐顺序：** E1（同步基线）→ E2/E3（异步）→ E4→E5→E6 → F1 → 面试稿

---

## Phase 5 监控指标速查（全局）

| 观察点 | PromQL / 观测方式 |
|--------|-------------------|
| API QPS（同步） | `sum(rate(http_server_requests_seconds_count{application="device-report-service",uri=~".*reports"}[1m]))` |
| API QPS（异步 202） | `...{uri=~".*reports-async",status="202"}...` |
| API P99 | `histogram_quantile(0.99, sum(rate(http_server_requests_seconds_bucket{application="device-report-service"}[1m])) by (le))` |
| HikariCP pending | `hikaricp_connections_pending{application="device-report-service"}` |
| HikariCP active | `hikaricp_connections_active{application="device-report-service"}` |
| Kafka 生产速率 | `sum(rate(kafka_producer_record_send_total{application="device-report-service"}[1m]))` |
| Consumer lag | `kafka_consumer_fetch_manager_records_lag` 或 Burrow/exporter；lab 可用日志 + `kafka-consumer-groups.sh` |
| Consumer 批量写入 QPS | `sum(rate(http_server_requests_seconds_count{application="device-report-consumer"}[1m]))` 或自定义 counter |
| Redis 命中率 | 应用自定义 `cache_hit_total` / `cache_miss_total` |
| 网关 429 | `apisix_http_status{route="device-report-service",code="429"}` |
| 金丝雀 v2 5xx | `sum(rate(http_server_requests_seconds_count{version="v2",status=~"5.."}[1m]))` |

---

## Implementation Tasks

### Task 1: Kafka 基础设施（WSL Docker）

**Files:**
- Create: `iot-learn-lab/infra/kafka/docker-compose-kafka.yml`
- Create: `iot-learn-lab/infra/kafka/create-topics.sh`
- Create: `iot-learn-lab/infra/kafka/README-kafka.md`

- [ ] **Step 1: 编写 docker-compose（单节点 KRaft，适合 lab）**

```yaml
# 要点：advertised.listeners 必须包含 Windows 可达地址 192.168.19.64:9092
services:
  kafka:
    image: apache/kafka:3.9.0
    ports:
      - "9092:9092"
    environment:
      KAFKA_NODE_ID: 1
      KAFKA_PROCESS_ROLES: broker,controller
      KAFKA_LISTENERS: PLAINTEXT://0.0.0.0:9092,CONTROLLER://0.0.0.0:9093
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://192.168.19.64:9092
      KAFKA_CONTROLLER_QUORUM_VOTERS: 1@localhost:9093
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 1
```

- [ ] **Step 2: 启动并验证**

```bash
cd iot-learn-lab/infra/kafka
docker compose -f docker-compose-kafka.yml up -d
docker compose -f docker-compose-kafka.yml ps
```

- [ ] **Step 3: 创建 Topic**

```bash
# create-topics.sh
TOPIC=device-report-events
PARTITIONS=3
REPLICATION=1
# kafka-topics.sh --create --topic $TOPIC --partitions $PARTITIONS ...
```

- [ ] **Step 4: 从 WSL 与 Windows 双向验证**

```bash
# WSL 生产测试消息
kafka-console-producer.sh --bootstrap-server 192.168.19.64:9092 --topic device-report-events

# Windows（若安装了 kafka 客户端）或 WSL consumer
kafka-console-consumer.sh --bootstrap-server 192.168.19.64:9092 --topic device-report-events --from-beginning
```

- [ ] **Step 5: 在 README 记录 advertised.listeners 踩坑**

Windows 应用 **必须** 连 `192.168.19.64:9092`，不能写 `localhost:9092`（那是 WSL 内部视角）。

- [ ] **Step 6: Commit**

```bash
git add iot-learn-lab/infra/kafka/
git commit -m "feat(phase5): add Kafka docker compose and topic bootstrap"
```

**验收与观测（Task 1 完成后）**

| 检查项 | 预期 | 在哪里看 |
|--------|------|----------|
| Broker 存活 | `docker ps` 中 kafka Up | WSL |
| Topic 存在 | `device-report-events`，3 partitions | `kafka-topics.sh --list` |
| 网络可达 | Windows `telnet 192.168.19.64 9092` 或 producer 测试成功 | Windows |

**效果说明：** 尚未写代码，仅打通 **Windows Producer/Consumer → WSL Kafka** 消息通路。面试可讲：IoT 峰值写入先进入 **持久化日志（Kafka）**，避免同步写库拖垮 API。

---

### Task 2: device-report 异步上报 Producer

**Files:**
- Modify: `iot-learn-lab/device-report-service/pom.xml`
- Create: `.../messaging/DeviceReportEvent.java`
- Create: `.../messaging/DeviceReportProducer.java`
- Create: `.../controller/DeviceReportAsyncController.java`
- Modify: `application.yml` — Kafka producer 配置

- [ ] **Step 1: 添加依赖**

```xml
<dependency>
    <groupId>org.springframework.kafka</groupId>
    <artifactId>spring-kafka</artifactId>
</dependency>
```

- [ ] **Step 2: application.yml 增加 Kafka（Windows 连 WSL）**

```yaml
spring:
  kafka:
    bootstrap-servers: ${KAFKA_BOOTSTRAP:192.168.19.64:9092}
    producer:
      key-serializer: org.apache.kafka.common.serialization.StringSerializer
      value-serializer: org.springframework.kafka.support.serializer.JsonSerializer
      acks: all
      retries: 3
      properties:
        linger.ms: 5          # 微批次，利于吞吐
        batch.size: 16384

app:
  kafka:
    topic: ${KAFKA_TOPIC:device-report-events}
```

- [ ] **Step 3: 定义事件 DTO**

```java
public record DeviceReportEvent(
    String eventId,
    String deviceId,
    Map<String, Object> payload,
    Instant reportedAt
) {}
```

- [ ] **Step 4: 实现 Producer**

```java
@Service
public class DeviceReportProducer {
    public CompletableFuture<SendResult<String, DeviceReportEvent>> send(DeviceReportEvent event) {
        return kafkaTemplate.send(topic, event.deviceId(), event);
    }
}
```

- [ ] **Step 5: 新增异步 API（保留原同步 `/reports` 不变，便于 E1/E2 对比）**

```java
@RestController
@RequestMapping("/api/v1/devices/{deviceId}/reports-async")
public class DeviceReportAsyncController {
    @PostMapping
    @ResponseStatus(HttpStatus.ACCEPTED)  // 202
    public Map<String, String> postReportAsync(...) {
        producer.send(event);
        return Map.of("eventId", eventId, "status", "ACCEPTED");
    }
}
```

- [ ] **Step 6: 启用 Micrometer Kafka 指标**

确认 `management.metrics.enable.kafka` 未关闭；`/actuator/prometheus` 可见 `kafka.producer.*`。

- [ ] **Step 7: 单条验证**

```bash
curl -s -w "\nHTTP %{http_code}\n" -X POST \
  "$DIRECT_URL/api/v1/devices/e2-dev-1/reports-async" \
  -H "Content-Type: application/json" \
  -d '{"payload":{"temperature":25}}'
# 预期 HTTP 202，body 含 eventId
```

- [ ] **Step 8: Commit**

**验收与观测（Task 2 完成后）**

| 检查项 | 预期 | PromQL / 命令 |
|--------|------|---------------|
| 异步 API | HTTP **202**，毫秒级响应 | curl 计时 |
| Kafka 有消息 | consumer 未启动时 topic 堆积 | `kafka-console-consumer.sh --from-beginning` |
| Producer 指标 | send rate > 0 | `rate(kafka_producer_record_send_total{application="device-report-service"}[1m])` |

**效果说明：** **同步 vs 异步的第一对比点** — API 层不再等待 INSERT 完成。E1 仍用 `/reports`；E2 改用 `/reports-async`。面试话术：「接受请求 ≠ 落库完成，202 + 消息队列解耦峰值。」

---

### Task 3: device-report-consumer 批量落库

**Files:**
- Create: `iot-learn-lab/device-report-consumer/`（新 Maven 模块）
- Modify: `iot-learn-lab/pom.xml` — `<module>device-report-consumer</module>`
- Create: `DeviceReportBatchListener.java`、`DeviceReportBatchWriter.java`

- [ ] **Step 1: 模块骨架**

- port: `8768`
- `spring.application.name: device-report-consumer`
- 复用 PostgreSQL 连接与 `DeviceReport` 实体（可抽 `iot-learn-common` 或复制 entity + repository）

- [ ] **Step 2: 消费者配置（批量拉取）**

```yaml
spring:
  kafka:
    bootstrap-servers: ${KAFKA_BOOTSTRAP:192.168.19.64:9092}
    consumer:
      group-id: device-report-consumer-group
      enable-auto-commit: false
      max-poll-records: 100
    listener:
      type: batch
      ack-mode: manual_immediate
```

- [ ] **Step 3: Batch Listener**

```java
@KafkaListener(topics = "${app.kafka.topic}", containerFactory = "batchFactory")
public void onMessages(List<ConsumerRecord<String, DeviceReportEvent>> records, Acknowledgment ack) {
    batchWriter.writeBatch(records);
    ack.acknowledge();
}
```

- [ ] **Step 4: 批量 INSERT（JPA batch 或 JDBC batch）**

```yaml
spring.jpa.properties.hibernate.jdbc.batch_size: 50
spring.jpa.properties.hibernate.order_inserts: true
```

- [ ] **Step 5: 暴露 health + prometheus**

- [ ] **Step 6: 启动 consumer，消费 Task 2 积压消息，查 PG 行数增加**

- [ ] **Step 7: Prometheus 增加 scrape `:8768`**

- [ ] **Step 8: Commit**

**验收与观测（Task 3 完成后）**

| 检查项 | 预期 | 在哪里看 |
|--------|------|----------|
| 消费组注册 | `device-report-consumer-group` stable | `kafka-consumer-groups.sh --describe` |
| Lag 下降 | 生产 1000 条后 lag → 0 | consumer groups `LAG` 列 |
| PG 数据 | `device_report` 表行数与 event 数一致 | `SELECT count(*) FROM device_report` |
| 批量效果 | 日志每 poll 处理 N 条 | consumer 日志 |

```promql
# consumer 所在 JVM 线程 / DB 连接（可选）
hikaricp_connections_active{application="device-report-consumer"}
```

**效果说明：** 完成 **「Kafka 填谷」** — 峰值在 Topic 缓冲，Consumer 按批次平稳写库。E3 场景观察 **lag 曲线先升后降**。面试：批量 INSERT 降低 DB 连接开销，是 IoT 海量上报常见模式。

---

### Task 4: E1/E2 对比实验与 Grafana「Async / Kafka」行

**Files:**
- Modify: `iot-learn-lab/infra/grafana/dashboards/device-report-observability.json`
- Create: `iot-learn-lab/scripts/phase5/scenario-e1-sync-10x-burst.sh`
- Create: `iot-learn-lab/scripts/phase5/scenario-e2-async-10x-burst.sh`

- [ ] **Step 1: E1 脚本 — 同步 10x 突增**

基于 `phase1/scenario-s2-device-burst.sh`：
- `BURST_MULTIPLIER=10` → 每轮 1000 设备（100×10）
- 目标 URL：`$DIRECT_URL/api/v1/devices/device-$i/reports`
- 时长默认 60s

- [ ] **Step 2: E2 脚本 — 异步 10x 突增**

同样倍率，URL 改为 `/reports-async`，统计 202 比例。

- [ ] **Step 3: Grafana 新增 Row「Async / Kafka (Phase 5)」**

| Panel | PromQL |
|-------|--------|
| 同步 API P99 | `histogram_quantile(0.99, sum(rate(http_server_requests_seconds_bucket{application="device-report-service",uri=~".*/reports"}[1m])) by (le))` |
| 异步 API P99 | `... uri=~".*/reports-async" ...` |
| HikariCP pending | `hikaricp_connections_pending{application="device-report-service"}` |
| Kafka send rate | `sum(rate(kafka_producer_record_send_total{application="device-report-service"}[1m]))` |
| Consumer lag | consumer group CLI 或 exporter 指标 |

- [ ] **Step 4: 先跑 E1 截图，再跑 E2 截图，同一 Dashboard 对比**

- [ ] **Step 5: Commit**

**验收与观测（Task 4 完成后）**

| 场景 | 关键现象 | 面试要点 |
|------|----------|----------|
| **E1 同步** | pending↑、P99↑、可能出现 5xx/慢响应 | 连接池打满是 API 层雪崩前兆 |
| **E2 异步** | API P99 低、202 占主导；lag 可能升 | **削峰**：保护 API 与 DB 之间的缓冲 |

```promql
# E1 vs E2 核心对比（压测期间）
hikaricp_connections_pending{application="device-report-service"}
histogram_quantile(0.99, sum(rate(http_server_requests_seconds_bucket{application="device-report-service"}[1m])) by (le))
```

**效果说明：** 这是 W9 **第一个面试故事** — 「10 倍峰值时为什么选 Kafka」。用 **同倍率、不同路径** 的对照实验，比口述更有说服力。

---

### Task 5: E3 Kafka Lag 观测脚本

**Files:**
- Create: `iot-learn-lab/scripts/phase5/scenario-e3-kafka-lag-observe.sh`

- [ ] **Step 1: 脚本逻辑**

1. **停止** consumer（或暂停 listener）模拟消费能力不足
2. E2 异步压测 30s
3. 记录 lag 峰值（`kafka-consumer-groups.sh --describe`）
4. **启动** consumer，每 5s 打印 lag 直到 0
5. 打印 PromQL 提示

- [ ] **Step 2: 文档说明 lag 与 SLA 关系**

消费慢 ≠ API 失败；但 lag 长期堆积意味着 **数据延迟变大**，需扩容 consumer 或优化 batch。

- [ ] **Step 3: Commit**

**验收与观测（Task 5 完成后）**

| 检查项 | 预期 |
|--------|------|
| 压测中 lag | > 0 且持续上升 |
| 恢复消费后 | lag 单调下降至 0 |
| PG 最终一致 | 总条数 = 生产条数（at-least-once 下可接受重复，lab 可用 eventId 去重） |

**效果说明：** 讲清 **「异步接受」与「最终落库」** 之间的时间窗口 — IoT 场景常可接受秒级延迟，不可接受 API 超时。

---

### Task 6: Redis 读缓存与三高防护实现

**Files:**
- Create: `.../service/DeviceStatsCacheService.java`
- Create: `.../controller/DeviceStatsController.java`
- Modify: `application.yml` — 缓存 TTL、开关

- [ ] **Step 1: 读 API 设计**

```
GET /api/v1/devices/{deviceId}/stats
→ { "deviceId", "reportCount", "lastReportedAt", "source": "redis|db" }
```

统计逻辑：`SELECT count(*), max(reported_at) FROM device_report WHERE device_id = ?`

- [ ] **Step 2: 基础缓存（Cache-Aside）**

```
key: device:stats:{deviceId}
TTL: 60s + random(0..30)   # 防雪崩（E6）
value: JSON
```

- [ ] **Step 3: 穿透防护（E4）— 空值缓存**

DB 查无此 device 时，缓存 `"NULL"` 占位，TTL 30s，避免同一 fake id 打穿 DB。

- [ ] **Step 4: 击穿防护（E5）— 互斥锁 / 单飞**

热点 key 过期时，仅一个线程查 DB 并回填，其余短暂等待或返回旧值（lab 可用 `synchronized` + 双重检查，或 Redisson 简版）。

- [ ] **Step 5: 自定义 Micrometer 指标**

```java
Counter.builder("cache_access_total").tag("result", "hit|miss|null_hit").register(...)
```

- [ ] **Step 6: 单 deviceId 压测验证命中率**

- [ ] **Step 7: Commit**

**验收与观测（Task 6 完成后）**

| 防护 | 触发方式 | 预期 |
|------|----------|------|
| 穿透 | 连续请求不存在的 id | 首次 miss+DB；之后 `null_hit`，DB QPS≈0 |
| 击穿 | 热点 key 过期 + 100 并发 | 无锁时 DB 尖峰；有锁时仅 1 次 DB |
| 雪崩 | 批量 key 同 TTL 过期 | 随机 TTL 后 DB 曲线平滑 |

```promql
rate(cache_access_total{result="hit"}[1m])
/
rate(cache_access_total[1m])
```

**效果说明：** 与 Phase 3 Redis **降级缓存**（写路径、保可用）区分 — 本 Task 是 **读路径、保性能**。面试常问三高；lab 用 **同一 stats API** 分三个脚本演示。

---

### Task 7: 缓存场景脚本 E4–E6

**Files:**
- Create: `scripts/phase5/scenario-e4-cache-penetration.sh`
- Create: `scripts/phase5/scenario-e5-cache-breakdown.sh`
- Create: `scripts/phase5/scenario-e6-cache-avalanche.sh`

- [ ] **Step 1: E4 — 穿透**

100 次请求 `deviceId=fake-$i`（均不存在）→ 对比开关 `app.cache.null-cache-enabled=false/true`

- [ ] **Step 2: E5 — 击穿**

对同一 `hot-device` 预热 → 等待 TTL 过期 → 并发 50 请求 → 观察 DB 连接 / 慢查询

- [ ] **Step 3: E6 — 雪崩**

脚本批量写入 100 个 device stats 缓存（固定 TTL）→ 同时过期 → 观察 PG QPS 尖峰 vs 随机 TTL

- [ ] **Step 4: 每脚本末尾打印 PromQL + Grafana 面板名**

- [ ] **Step 5: Commit**

**验收与观测（Task 7 完成后）**

| 场景 | 核心指标 | 一句话 |
|------|----------|--------|
| E4 | `cache_access_total{result="null_hit"}` | 空值缓存挡穿透 |
| E5 | DB QPS 尖峰宽度 | 互斥锁缩尖峰 |
| E6 | PG 查询 rate 波动 | 随机 TTL 分散过期 |

---

### Task 8: Grafana「Cache」行 + 指标汇总

**Files:**
- Modify: `device-report-observability.json`

- [ ] **Step 1: 新增 Row「Cache (Phase 5)」**

| Panel | 来源 |
|-------|------|
| 命中率 | `cache_access_total` |
| miss rate | `result="miss"` |
| stats API P99 | http histogram |

- [ ] **Step 2: 与 Phase 3 Redis 降级面板加 **文字注释** 区分读/写用途**

- [ ] **Step 3: Commit**

**验收与观测（Task 8 完成后）**

Dashboard 上 **Gateway / App / Sentinel / Canary / Async / Cache** 六行齐全，可作为 W10 演练单一入口。

---

### Task 9: W10 终极演练剧本与脚本 F1

**Files:**
- Create: `scripts/phase5/scenario-f1-ultimate-drill.sh`
- Create: `docs/phase5-ultimate-drill-runbook.md`

- [ ] **Step 1: 定义六幕剧本（脚本内 echo + sleep + 人工确认点）**

| 幕 | 动作 | 预期现象 | 观测 |
|----|------|----------|------|
| **1 常态** | 网关 none，v1 100% | 201/202 正常 | 基线 QPS |
| **2 流量突增** | E2 异步 10x 经网关 | 202 为主；lag 可控 | Gateway QPS、Kafka send |
| **3 网关限流** | `bootstrap-device-report-gateway.sh limit-count` | 429 出现 | `apisix_http_status{code="429"}` |
| **4 下游故障** | 停 command-dispatch | Feign 失败 | R5 式 fallback / Sentinel degrade |
| **5 金丝雀事故** | 90/10 + v2 bug on | v2 5xx↑ | Canary 行 v2 错误率 |
| **6 回滚** | `bootstrap-canary-rollback.sh` + bug off | 总错误率恢复 | v2 QPS→0 |

- [ ] **Step 2: 脚本参数**

```bash
DRILL_GATEWAY=1
DRILL_CANARY=1
DRILL_DISPATCH_DOWN=1   # 可选，需人工停 8767
PAUSE_BETWEEN_ACTS=30   # 秒，便于截图
```

- [ ] **Step 3: 每幕结束打印 **本幕 PromQL** 与 **通过标准****

- [ ] **Step 4: runbook 写「故障时间线」模板（T+0、T+1min…）**

- [ ] **Step 5: Commit**

**验收与观测（Task 9 完成后）**

| 检查项 | 预期 |
|--------|------|
| 单脚本可跑完全程 | 约 15–20min（含观察暂停） |
| 六幕均可截图 | Grafana 有清晰前后对比 |
| 能口述因果链 | 每一层解决什么问题 |

**效果说明：** W10 **不是新功能**，而是 **Phase 1–4 + W9 的导演剪辑**。面试用「我们做过一次完整演练」比散点实验更有说服力。

---

### Task 10: 面试故事集与架构一页纸

**Files:**
- Create: `docs/phase5-interview-notes.md`
- Create: `docs/phase5-k8s-concepts-preview.md`（概念预习，不上手集群）

- [ ] **Step 1: interview-notes 四故事模板**

1. **可观测性（W1–2）** — P99、错误率、告警优先级
2. **网关 + 韧性（W3–6）** — 429 vs 503 vs 504；雪崩 vs 熔断
3. **金丝雀（W7–8）** — 三策略；按 version 看错误率
4. **高并发（W9）** — 同步 vs 异步；Kafka lag；缓存三高

- [ ] **Step 2: 每故事 **现象 → 指标 → 手段 → 结果** 四段式**

- [ ] **Step 3: K8s 预习（仅概念）**

| 概念 | 与本 lab 映射 |
|------|---------------|
| Pod | 一个 Java 进程（8765） |
| Deployment | 滚动发布 device-report |
| Service | Nacos 服务发现 |
| Ingress | APISIX 网关 |
| HPA | 根据 QPS/lag 扩 consumer |

- [ ] **Step 4: Commit**

**验收与观测（Task 10 完成后）**

能 **15 分钟** 白板讲完 IoT 上报全链路；能回答 spec 中 W10 面试题「设计一个高可用 IoT 平台」。

---

### Task 11: phase5-async-cache-runbook.md

**Files:**
- Create: `iot-learn-lab/docs/phase5-async-cache-runbook.md`

- [ ] **Step 1:** 参照 `phase3-scenarios-runbook.md` 结构，写 E1–E6：
  - 前置条件
  - 逐步命令
  - 预期表
  - PromQL
  - 常见踩坑（Kafka advertised.listeners、202 不等于落库完成）

- [ ] **Step 2: Commit**

---

### Task 12: Phase 5 完成检查清单

- [ ] **Step 1:** 在 `iot-learn-lab/README.md` 或本 plan 末尾维护：

**Phase 5 完成检查清单**

- [ ] Kafka `:9092` 从 Windows 可达；Topic `device-report-events` 存在
- [ ] `/reports-async` 返回 202；consumer 批量落库；lag 可观测
- [ ] E1 vs E2 对比截图：同步 pending↑ vs 异步 P99 低
- [ ] E4/E5/E6 三高各至少跑通一次
- [ ] F1 终极演练六幕完成并截图
- [ ] `phase5-interview-notes.md` 四故事已填写
- [ ] 能口述：Kafka 削峰、缓存三高、与 Sentinel/金丝雀的分工

---

## W9 / W10 日程建议

| 天 | 场景 | Task | 时长 |
|----|------|------|------|
| D1 | Kafka 基建 | Task 1 | 2h |
| D2 | Producer | Task 2 | 3h |
| D3 | Consumer | Task 3 | 4h |
| D4 | E1/E2/E3 | Task 4–5 | 3h |
| D5 | 缓存三高 | Task 6–8 | 4h |
| D6 | E4–E6 脚本 | Task 7 | 2h |
| D7 | F1 终极演练 | Task 9 | 3h |
| D8 | 面试稿 + 文档 | Task 10–12 | 4h |

---

## W10 终极演练：层叠防护参考图

```
流量突增
   ↓
[L2 APISIX limit-count]  → 429，保护入口
   ↓
[device-report API]
   ├─ 异步 202 → Kafka（削峰）
   └─ Feign → [L3 Sentinel degrade] → fallback（下游挂）
   ↓
[Phase 4 金丝雀] v2 bug → 按 version 发现 → 权重回滚
   ↓
[观测] Grafana 六行面板 + 告警
```

---

## 参考

- Spec 总览: `docs/superpowers/specs/2026-07-02-ops-learning-plan-design.md`
- Phase 3 韧性: `docs/superpowers/plans/2026-07-05-phase3-application-resilience.md`
- Phase 4 金丝雀: `docs/superpowers/plans/2026-07-09-phase4-release-strategy.md`
- Spring Kafka: https://docs.spring.io/spring-kafka/reference/
- Kafka 设计: https://kafka.apache.org/documentation/
- Phase 4 面试笔记: `iot-learn-lab/docs/phase4-interview-notes.md`
