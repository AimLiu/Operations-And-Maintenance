# Phase 5 面试复盘笔记（W9–W10）

**日期：** 2026-07-11  
**范围：** Phase 5 — Kafka 异步削峰、Redis 读缓存三高、全链路综合演练  
**实验服务：** `device-report-service`（:8765）、`device-report-consumer`（:8768）、Kafka、Redis、PostgreSQL

> 操作步骤见：`docs/superpowers/plans/2026-07-10-phase5-capstone-interview.md`  
> 场景脚本：`scripts/phase5/scenario-e{1-6}*.sh`、`scenario-f1-ultimate-drill.sh`（F1 待补）  
> 前序复盘：`phase3-interview-notes.md`（韧性）、`phase4-interview-notes.md`（金丝雀）

---

## 场景记录

| 场景 | 日期 | 通过？ | 关键现象 | 截图/链接 |
|------|------|--------|----------|-----------|
| E1 同步 10x 突增 | | ☐ | HikariCP pending↑；同步 P99 恶化 | |
| E2 异步 10x 突增 | | ☐ | 202 为主；API P99 低于 E1 | |
| E3 Kafka lag | | ☐ | 停 consumer lag↑；启动后 lag↓ | |
| E4 缓存穿透 | | ☐ | 第 1 次 db；后续 redis-null | |
| E5 缓存击穿 | | ☐ | 锁开：db≈1；锁关：db 多次 | |
| E6 缓存雪崩 | | ☐ | 固定 TTL：db≈100；jitter：db+redis 混合 | |
| F1 终极演练 | | ☐ | 限流→熔断→金丝雀→回滚串联 | |

### E1 vs E2 对比截图位

**E1 同步（HikariCP / P99）：**

（截图）

**E2 异步（202 / Kafka send / P99）：**

（截图）

### E3 lag 曲线截图位

**Offset Explorer / consumer-groups LAG 先升后降：**

（截图）

---

## E1 vs E2 对比（面试重点）

| 指标 | E1 同步 `/reports` | E2 异步 `/reports-async` |
|------|-------------------|--------------------------|
| 典型 HTTP | 201 | **202** |
| API P99 | | |
| `hikaricp_connections_pending`（service） | | |
| `spring_kafka_template_seconds_count` | 无 / 0 | |
| Consumer lag | — | |
| 落库时机 | 请求内同步 INSERT | Kafka 消费后批量 INSERT |

**PromQL：**

```promql
# 同步 P99
histogram_quantile(0.99,
  sum(rate(http_server_requests_seconds_bucket{
    application="device-report-service",
    uri=~".*/reports"
  }[1m])) by (le)
)

# 异步 P99（查 device-report-service，不是 consumer）
histogram_quantile(0.99,
  sum(rate(http_server_requests_seconds_bucket{
    application="device-report-service",
    uri=~".*reports-async"
  }[1m])) by (le)
)

hikaricp_connections_pending{application="device-report-service"}
hikaricp_connections_active{application="device-report-consumer"}

sum(rate(spring_kafka_template_seconds_count{
  application="device-report-service", result="success"
}[1m]))
```

**面试一句：** 同步路径 API 与 DB 耦合，峰值易打满连接池；异步路径 **先接请求（202）再填谷落库**，保护入口 SLA，代价是 **最终一致性** 与 **lag 窗口**。

---

## 面试题 1：IoT 高并发怎么设计？Kafka 怎么削峰？

### 精炼结论（面试版）

**分层思路：**

```text
设备上报 → 网关（限流）→ API（快速受理）→ Kafka（缓冲）
                                              ↓
                                    Consumer 批量写 PostgreSQL
```

| 层次 | 手段 | 本 lab 对应 |
|------|------|-------------|
| 入口 | APISIX limit-count | Phase 2 / F1 第 3 幕 |
| 受理 | 异步 202 + Kafka | E2 `/reports-async` |
| 削峰 | Topic 积压 + consumer 填谷 | E3 lag 观测 |
| 写库 | JDBC batch / JPA flush 批次 | `DeviceReportBatchWriter` |
| 读路径 | Redis stats 缓存 + 三高防护 | E4–E6 |
| 下游故障 | Sentinel + Feign fallback | Phase 3 R5/R6 |
| 发布风险 | 金丝雀 + 按 version 观测 | Phase 4 C2–C4 |

### Kafka 削峰话术

> 峰值时 Producer 把消息写入 Kafka 日志，API 快速返回 202；Consumer 按自身能力批量消费落库。  
> **lag** 表示消费积压，可升可降；API 202 只代表「已接收」，不代表「已落库」。  
> 扩容方向：增加 consumer 实例数（≤ 分区数）或提高 `max.poll.records` / batch insert。

### 常见追问

| 问题 | 答法 |
|------|------|
| 202 成功但 DB 没有？ | consumer 未启动 / lag 堆积 / 消费失败未 ack |
| lag 一直不降？ | consumer 挂了、消费慢于生产、需扩容 |
| 为什么分区 lag 依次降？ | **单 consumer 单线程** 顺序 poll→处理→commit，不是 Kafka 时间片轮转 |
| at-least-once 重复？ | 本 lab 无 `event_id` 去重，重投可能重复 INSERT |

---

## 面试题 2：缓存穿透 / 击穿 / 雪崩区别？

### 三高对照表

| 问题 | 现象 | 根因 | 本 lab 手段 | 场景 |
|------|------|------|-------------|------|
| **穿透** | 查**不存在**的数据，缓存永不命中 | 无空值缓存，每次都打 DB | `__NULL__` 占位 + 短 TTL | E4 |
| **击穿** | **热点 key** 过期瞬间，并发打 DB | 单点失效 + 高并发 | Redis `SETNX` 互斥锁 + 双重检查 | E5 |
| **雪崩** | **大量 key** 同时过期 | TTL 相同，集体失效 | TTL = base + **random jitter** | E6 |

### 与 Phase 3 Redis 的区别

| 维度 | Phase 3（R6） | Phase 5（Task 6） |
|------|---------------|-----------------|
| 路径 | **写路径** Feign 降级 | **读路径** GET `/stats` |
| Key | `dispatch:ack:{deviceId}` | `device:stats:{deviceId}` |
| 目的 | 保**可用**（下游挂了仍有 ack） | 保**性能**（减 DB 读压力） |
| 指标 | 业务字段 `source=redis-cache` | `cache_access_total{result=...}` |

### E4 / E5 / E6 预期速记

| 场景 | 关键结果 |
|------|----------|
| **E4** | 同一 fake id：第 1 次 `source=db`，之后 `source=redis-null` |
| **E5** | `breakdown-lock-enabled=true`：并发 50，db 1~少数，redis 绝大多数 |
| **E6** | 固定 TTL：db≈100；随机 jitter：db 明显少于 100 |

**PromQL：**

```promql
rate(cache_access_total{application="device-report-service",result="hit"}[1m])
rate(cache_access_total{application="device-report-service",result="miss"}[1m])
rate(cache_access_total{application="device-report-service",result="null_hit"}[1m])
```

### `loadWithBreakdownLock` 一句话

> 热点 key 过期时，用 Redis 锁保证**只有一个线程查库回填**，其他线程等待后读缓存，避免击穿。

---

## 面试题 3：设计一个高可用 IoT 平台（W10 综合题）

### 四故事串联（现象 → 指标 → 手段 → 结果）

#### 故事 1：可观测性（W1–2）

| 项 | 内容 |
|----|------|
| **现象** | 流量突增时不知慢在网关、应用还是 DB |
| **指标** | P99、错误率、`up`、HikariCP pending |
| **手段** | Prometheus + Grafana 分层面板 |
| **结果** | 先定位层级，再决定限流/扩容/回滚 |

#### 故事 2：网关 + 韧性（W3–6）

| 项 | 内容 |
|----|------|
| **现象** | 下游 dispatch 挂掉，上游线程阻塞 |
| **指标** | P99 飙升、`jvm_threads_live` 升 |
| **手段** | APISIX 429（入口）+ Sentinel degrade + Feign/Redis fallback |
| **结果** | R5：快速失败，上游存活 |

#### 故事 3：金丝雀发布（W7–8）

| 项 | 内容 |
|----|------|
| **现象** | v2 有 bug，10% 流量已中招 |
| **指标** | **按 version** 看 v2 5xx，总错误率仅略升 |
| **手段** | APISIX 权重回滚 100% v1；Nacos 热开关修 bug |
| **结果** | 影响面可控，分钟级止血 |

#### 故事 4：高并发削峰（W9）

| 项 | 内容 |
|----|------|
| **现象** | 同步写入打满连接池，API 变慢 |
| **指标** | E1 pending↑；E2 异步 P99 低、lag 可观测 |
| **手段** | Kafka 异步 + consumer 批量落库 + 读缓存三高 |
| **结果** | 入口稳定，落库延迟可接受 |

### 白板全链路（15 分钟版）

```text
IoT 设备
   ↓
[APISIX] 限流 429 ───────────────────── L2 入口防护
   ↓
[device-report-service]
   ├─ POST /reports-async → 202 → Kafka ─── 削峰
   ├─ GET  /stats → Redis（E4/E5/E6）────── 读性能
   └─ Feign → dispatch
              └─ Sentinel degrade / Redis fallback ─ L3 运行时韧性
   ↓
[device-report-consumer] batch INSERT → PostgreSQL
   ↓
[Prometheus/Grafana] QPS / P99 / lag / cache / version
   ↓
[金丝雀] v1/v2 权重 → 异常则回滚
```

### F1 终极演练六幕（待跑）

| 幕 | 动作 | 观测 |
|----|------|------|
| 1 | 常态 | 基线 QPS |
| 2 | E2 经网关 | 202、Kafka send |
| 3 | APISIX limit-count | 429 |
| 4 | 停 dispatch | fallback / degrade |
| 5 | 金丝雀 v2 bug | v2 5xx↑ |
| 6 | 回滚 v1 | 总错误率恢复 |

---

## 面试题自测（Phase 5 专项）

1. 同步写库 vs Kafka 异步，各适合什么 SLA？
2. `202` 与 `201` 对客户端语义有何不同？如何查 lag？
3. 为什么异步 P99 查 `device-report-service` 而不是 consumer？
4. `hikaricp_connections_pending` 一直是 0 说明什么？（E2 正常；E1 可能负载不够）
5. 穿透 / 击穿 / 雪崩如何区分？各对应什么 Redis 策略？
6. `@RefreshScope` 与 Nacos 配置热更新关系？（Phase 4 C6，与发布并行理解）
7. 金丝雀 10% 时总错误率与 v2 错误率关系？（≈ 0.1 × v2_error_rate）
8. 单 consumer 为何分区 lag 依次下降？如何并行消费？
9. 流量回滚（C4）vs 功能开关（C6）区别？
10. 若只能选一个指标做发布告警，选什么？（按 version 的 v2 错误率 + 持续时长）

### 自测总评（2026-07-12）

| 题号 | 得分感 | 待加强 |
|------|--------|--------|
| 1 | 8/10 | 补 SLA 语义（一致性 vs 延迟） |
| 2 | 6/10 | lag 不是 offset 重置策略 |
| 3 | 7/10 | 强调 HTTP 指标在 producer 服务上 |
| 4 | 6/10 | E2/E1 分开解释 |
| 5 | 7/10 | 击穿时其他请求等 Redis，不是打 DB |
| 6 | 5/10 | 补 RefreshEvent + Bean 重建机制 |
| 7 | 7/10 | 表述：总错误率 ≈ 0.1 × v2 |
| 8 | 8/10 | 非 Kafka 时间片，是单线程 poll |
| 9 | 9/10 | — |
| 10 | 6/10 | 必须按 version=v2 + 持续时长 |

---

## 自测参考答案（含初答批改）

### 题 1：同步写库 vs Kafka 异步，各适合什么 SLA？

**我的初答（摘要）：** QPS 不高用同步，省组件；QPS 高或复杂时用 Kafka 解耦、削峰。

**批改：** 方向对，需补 **SLA 语义**，不只谈 QPS。

**精炼结论（面试版）：**

| 维度 | 同步写库 | Kafka 异步 |
|------|----------|------------|
| **一致性** | 强一致（201 ≈ 已落库） | 最终一致（202 ≈ 已入队） |
| **SLA** | 「写入成功」= DB 有记录 | 「受理成功」≠ 已落库；另需 **lag SLA** |
| **适用** | 低 QPS、强实时、链路简单 | 峰值高、可接受秒级~分钟级延迟 |
| **代价** | DB/连接池压力大 | 组件多、运维 lag、需幂等 |

**面试一句：** 先看业务能否接受 **最终一致性** 和 **处理延迟**，再看 QPS。

---

### 题 2：`202` 与 `201`？如何查 lag？

**我的初答（摘要）：** 202 表示已接收但未处理完；201 表示已处理成功。lag 可能与 consumer 从头/从最新消费有关。

**批改：** 202/201 **正确**；lag 理解 **需纠正**——与 `auto-offset-reset` 无关。

**精炼结论：**

| HTTP | 语义 |
|------|------|
| **201** | 资源已创建，**本次请求处理完成**（同步写库完成） |
| **202** | 请求已**接受**，处理**尚未完成**（已入 Kafka，未保证落库） |

**lag 定义：**

```text
LAG = LOG-END-OFFSET − CURRENT-OFFSET（按消费组 + 分区）
```

表示 **消费积压**，不是「从哪开始消费」的配置。

**怎么查 lag：**

- Offset Explorer 的 **Lag** 列
- `kafka-consumer-groups.sh --describe --group device-report-consumer-group`
- Prometheus：`kafka_consumer_fetch_manager_records_lag`（若已暴露）

**面试一句：** 202 = 已接单；lag = 积压多少还没落库。

---

### 题 3：为什么异步 P99 查 service 不查 consumer？

**我的初答（摘要）：** 发完 Kafka 就返回 202，跨服务统计较复杂。

**批改：** 结论对；理由应改为 **指标挂载点**。

**精炼结论：**

- `/reports-async` 是 **device-report-service:8765** 的 HTTP 接口
- **consumer 没有这条 HTTP 路径**，只有 Kafka 消费 + 写库
- `http_server_requests_*` 自然在 producer 上，不在 8768

**面试一句：** P99 量的是 **API 响应时间**，异步 API 在 producer 服务上。

---

### 题 4：`hikaricp_connections_pending` 一直是 0？

**我的初答（摘要）：** DB 无压力，无长时间操作。

**批改：** 部分对，需 **分场景**。

**精炼结论：**

| 场景 | pending=0 含义 |
|------|----------------|
| **E2 异步** | **正常** — service 基本不写库 |
| **E1 同步** | 池子够用 / 压测未打满 / Prometheus 漏掉尖峰 |
| **看 consumer 写库** | 查 `application="device-report-consumer"` 的 HikariCP |

pending=0 = **当前无线程排队等连接**，不等于「系统没压力」。

---

### 题 5：穿透 / 击穿 / 雪崩 + Redis 策略？

**我的初答（摘要）：** 穿透用空值缓存；击穿用并发控制、旁路写回，其他请求打 DB；雪崩用随机过期。

**批改：** 穿透、雪崩 **正确**；击穿 **「其他请求打 DB」说错了**。

**精炼结论：**

| 问题 | 现象 | Redis 策略（本 lab） |
|------|------|---------------------|
| **穿透** | 查不存在的数据，反复 miss | 空值缓存 `__NULL__`（E4） |
| **击穿** | 热点 key 过期，并发 miss | **互斥锁**：一线程查库回填，**其余等 Redis**（E5） |
| **雪崩** | 大量 key 同时过期 | TTL = base + **random jitter**（E6） |

**纠偏：** 击穿时其他请求应 **等待后读 Redis**，不是 **直接打 DB**。

---

### 题 6：`@RefreshScope` 与 Nacos 热更新？

**我的初答（摘要）：** `@RefreshScope` 标注热更新配置，常与 Nacos 搭配。

**批改：** 太浅，需讲 **机制**。

**精炼结论：**

```text
Nacos 推送 → RefreshEvent → Environment 更新
                              ↓
                    @RefreshScope Bean 销毁并重建
                              ↓
                    @Value 重新注入，业务行为才变
```

- 仅有 `Refresh keys changed` **不够**（普通 Bean 的 `final` 字段不变）
- `@ConditionalOnProperty` **不能**热切换 Bean 是否创建
- C6 = **功能开关**；C4 = **流量回滚**（不同层面）

---

### 题 7：金丝雀 10% 时总错误率与 v2 错误率？

**我的初答（摘要）：** v2 流量 1/10，总错误率 ×10 ≈ v2 真实错误率。

**批改：** 数学关系 **对**，建议更清晰表述。

**精炼结论：**

- 设 v1 错误率 ≈ 0，v2 错误率为 `Ev2`
- **总错误率** ≈ `0.1 × Ev2`
- 反例：总错误率 0.5% → **v2 约 5%**

**面试一句：** 发布 **不能只看总错误率**，必须 **按 `version=v2` 拆分**；总指标会被 90% 的 v1 稀释。

---

### 题 8：单 consumer 分区 lag 依次下降？如何并行？

**我的初答（摘要）：** consumer 轮转消费三个分区，非并行；可 `@KafkaListener(concurrency=x)`。

**批改：** **正确**；可补充：不是 Kafka 时间片调度。

**精炼结论：**

- 单线程 **poll → 处理 → commit**，lag 错峰下降
- **并行方式：**
  1. `@KafkaListener(concurrency = "3")`（≤ 分区数）
  2. 同 group 多实例（总数 ≤ 分区数）

---

### 题 9：流量回滚（C4）vs 功能开关（C6）？

**我的初答（摘要）：** C4 流量引回旧版；C6 Nacos 热更新动态开关功能；不同层面。

**批改：** **很好**。

**精炼结论：**

| | C4 流量回滚 | C6 功能开关 |
|--|-------------|-------------|
| **层面** | APISIX 权重 | Nacos 配置 |
| **效果** | 用户不再打到 v2 | v2 仍可接流量，行为改变 |
| **手段** | `bootstrap-canary-rollback.sh` | `@RefreshScope` + Nacos |

---

### 题 10：发布告警只选一个指标？

**我的初答（摘要）：** 错误率 + 持续时长。

**批改：** 方向对，需 **具体化**。

**精炼结论：**

> **v2 分版本 5xx 错误率**（`version="v2"`），**持续超过阈值 N 分钟**（如 v2 5xx > 5% 持续 5min）→ 触发回滚/告警。

**不要**只用全局错误率——10% 金丝雀时会被严重稀释。

可选第二信号：v2 P99 突增、Kafka lag 长期不降。

---

### 10 题速背版

1. 同步强一致+201；异步最终一致+202+lag SLA。  
2. 202=已接单；lag=消费积压，用 consumer-groups / Offset Explorer 查。  
3. 异步 P99 在 **service**，HTTP 在 8765。  
4. pending=0 瞬时无排队；E2 正常，E1 可能未打满池。  
5. 穿透空值、击穿互斥锁回填、雪崩随机 TTL；击穿时其他请求 **等 Redis**。  
6. Nacos 刷新 Environment + `@RefreshScope` 重建 Bean 才生效。  
7. 总错误率 ≈ 0.1×v2 错误率；发布看 **version=v2**。  
8. 单线程消费致 lag 错峰；`concurrency` 或多实例并行。  
9. C4 切流量，C6 切功能。  
10. 告警：**v2 错误率 + 持续时长**，不用全局 alone。

### 建议额外掌握的 3 点

1. **202 之后如何确认落库？** 查 lag、对账 DB，或业务回调；本 lab 接受最终一致。  
2. **Phase 3 Redis 降级 vs Phase 5 读缓存** — R6 写路径保可用；E4–E6 读路径保性能。  
3. **F1 全链路一句** — 网关限流 → 异步削峰 → Sentinel 熔断 → 金丝雀按 version 发现 → 权重回滚。

---

## K8s 概念预习（与本 lab 映射）

> 本 lab **未上 K8s 集群**，面试可说明「本地用端口 + 脚本模拟，概念如下」。

| K8s 概念 | 作用 | 本 lab 对应 |
|----------|------|-------------|
| **Pod** | 最小运行单元 | 一个 Java 进程（8765 / 8768） |
| **Deployment** | 多副本 + 滚动更新 | v1/v2 双实例、金丝雀权重 |
| **Service** | 集群内服务发现 | Nacos `device-report-service` |
| **Ingress** | 集群外 HTTP 入口 | APISIX `:9080` |
| **ConfigMap / Secret** | 配置外置 | Nacos `device-report-v2-app.yaml` |
| **HPA** | 按指标自动扩缩 | 类比：lag 高 → 扩 consumer；QPS 高 → 扩 Pod |

**面试一句：** 本 lab 在裸机/IDEA + Docker 中间件上验证了云原生要解决的问题；上 K8s 后是把进程、发现、入口、配置、弹性用标准对象管理。

---

## 踩坑与修复记录（本阶段实测）

| 踩坑 | 原因 | 处理 |
|------|------|------|
| `kafka.producer.*` 找不到 | Spring Boot 3 主指标是 `spring_kafka_template_*` | 以 Template 指标为准 |
| 异步 P99 empty | 查错 `application=device-report-consumer` | 查 **service** 的 `reports-async` |
| Nacos 配置不生效 | Data ID 无 `.yaml` 后缀；缺 `@RefreshScope` | 对齐 Data ID；去掉 `@ConditionalOnProperty` |
| `Map.of` NPE | 缺 `@RequestBody`，event 字段 null | 对齐同步 API，只传 `payload` |
| E5 无 redis-cli | WSL 未装 | `docker exec` 容器内执行 |
| lag 分区依次降 | 单 consumer 单线程 | 增加实例或 `concurrency` |
| `pending` 一直 0 | E2 不写库；或 E1 未打满池 | S4 slow-query 或看 consumer 的 HikariCP |

---

## Phase 1–5 能力矩阵（面试收尾用）

| Phase | 周 | 核心能力 | 代表场景 |
|-------|-----|----------|----------|
| 1 | W1–2 | 可观测性 | S2/S4、P99、HikariCP |
| 2 | W3–4 | 网关防护 | G3 429、G5/G6 504/503 |
| 3 | W5–6 | 应用韧性 | R4/R5 雪崩、R6 Redis 降级 |
| 4 | W7–8 | 发布策略 | C2–C4 金丝雀、Nacos 热开关 |
| 5 | W9–10 | 高并发 + 综合 | E1–E6、F1 全链路 |

---

## 自由笔记

（实验数据、截图索引、面试官反馈、待深化问题）

### 我的实验数据摘录

| 场景 | 记录值 |
|------|--------|
| E1 同步 P99 | |
| E2 异步 P99 | |
| E3 lag 峰值 | |
| E4 db / redis-null 比 | |
| E5 并发 db 次数（锁 on/off） | |
| E6 阶段 A db 次数 | |

---

## 参考

- Phase 5 计划：`docs/superpowers/plans/2026-07-10-phase5-capstone-interview.md`
- Phase 4 面试笔记：`phase4-interview-notes.md`
- Phase 3 面试笔记：`phase3-interview-notes.md`
- Spec 总览：`docs/superpowers/specs/2026-07-02-ops-learning-plan-design.md`
