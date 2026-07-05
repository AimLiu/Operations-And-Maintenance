# Phase 1 可观测性 — 复盘与面试笔记

**日期：** 2026-07-03  
**范围：** Phase 1（W1–W2）— Prometheus、Grafana、HikariCP、APISIX 抓取、告警设计  
**实验服务：** `device-report-service`（端口 8765）

---

## 1. P99 / P95 vs 平均延迟

### 准确含义

| 指标 | 含义 |
|------|------|
| **P95** | 95% 的请求延迟 **≤** 这个值 |
| **P99** | 99% 的请求延迟 **≤** 这个值 |
| **平均值（mean）** | 所有请求延迟的算术平均 |

它们不是「前 99% 接口的平均时间」，而是 **延迟分布的分位数（percentile）**。

### 为什么生产更看 P99/P95

- **平均值**会被少量极慢或极快请求拉偏，不能代表大多数用户的体验。
- **P99** 回答的是：「最慢的那 1% 用户，最差能接受到什么水平？」
- IoT 场景里，若 1% 设备上报超时并重试，可能引发 **重试风暴**，因此 P99 往往比平均值更有预警价值。

### PromQL 示例

```promql
# P99 延迟
histogram_quantile(0.99,
  sum(rate(http_server_requests_seconds_bucket{application="device-report-service"}[5m])) by (le)
)

# P95 延迟
histogram_quantile(0.95,
  sum(rate(http_server_requests_seconds_bucket{application="device-report-service"}[5m])) by (le)
)
```

### 面试话术

> 平均值看整体趋势，P95/P99 看尾部延迟（tail latency）。SLO 通常基于 P99 而不是 mean。

---

## 2. 错误率 vs 高 QPS，哪个更紧急？

### 结论

**一般优先看错误率。** 高 QPS 不一定是事故，错误率升高往往意味着系统已经在失败。

### 告警优先级（参考）

```
服务不可用 (up=0)  >  错误率飙升  >  延迟劣化  >  连接池 pending  >  QPS 升高
```

### 高 QPS

- 可能是正常业务高峰。
- 若架构做过压测、有限流/扩容，高 QPS 本身不一定是问题。

### 错误率升高

- 往往意味着 bug、依赖故障、DB 异常、攻击等。
- 需要更快介入。

### 容量事故（高 QPS → 积压 → 全站变慢）

典型处理顺序：

1. 网关限流 / 降级，保护核心链路
2. 扩容应用或调整连接池（有手段时）
3. 异步削峰（Kafka 等）
4. 恢复后再逐步放开流量

### 面试话术

> QPS 是信号，错误率和 SLO 违反是告警。QPS 涨 + 错误率涨 + P99 涨，是容量或雪崩前兆。

---

## 3. `hikaricp_connections_pending > 0` 意味着什么？

### 含义

| 指标 | 含义 |
|------|------|
| `active` 接近 `max` | 连接都在使用 |
| `idle` 接近 0 | 没有空闲连接 |
| **`pending > 0`** | 新请求在排队等连接 ← **危险信号** |
| `timeout_total` 增加 | 等待超时，获取连接失败 |

**`pending > 0` 表示：有线程在等待 HikariCP 分配数据库连接，前面的 SQL 占用连接时间过长，连接池已饱和。**

这是雪崩链路中的常见环节：

```
慢 SQL → 连接长时间占用 → 池耗尽 → pending > 0 → 接口变慢 → 重试增多 → 进一步恶化
```

### PromQL

```promql
hikaricp_connections_pending{application="device-report-service"}
hikaricp_connections_active{application="device-report-service"}
hikaricp_connections_max{application="device-report-service"}

# 池使用率
hikaricp_connections_active / hikaricp_connections_max
```

### 排查顺序（7 步）

#### Step 1：确认是瞬时还是持续

在 Grafana 观察 `pending`、`active/max`：

- 偶尔 > 0：可能是短暂 burst
- **持续 > 0 且 active ≈ max**：需要处理

#### Step 2：对齐业务侧现象

- 同一时段 P99 是否升高？
- 错误率是否上升？
- 是否刚执行 S4 慢查询压测？

#### Step 3：PostgreSQL 查慢 SQL / 长事务

```sql
-- 当前活跃连接
SELECT pid, usename, state, wait_event_type, wait_event,
       now() - query_start AS query_age, query
FROM pg_stat_activity
WHERE datname = 'iot_learn'
  AND state != 'idle'
ORDER BY query_start;

-- 运行超过 3 秒的 SQL
SELECT pid, now() - query_start AS duration, query
FROM pg_stat_activity
WHERE datname = 'iot_learn'
  AND state = 'active'
  AND now() - query_start > interval '3 seconds';
```

#### Step 4：应用侧关联

- 是否某接口 QPS 突增（S2 场景）？
- 是否刚发布（引入慢 SQL、N+1 查询）？
- HikariCP 配置：`maximum-pool-size` 是否过小（本实验默认 10）？

#### Step 5：SQL 优化

- `EXPLAIN ANALYZE` 查看执行计划
- 补索引（如 `device_id`、`reported_at`）
- 避免热路径上的 `pg_sleep`、全表扫描
- 长任务改异步（Kafka 批量写入）

#### Step 6：临时止血（不能代替根因修复）

- 限流（APISIX / Sentinel）减少并发
- 适当调大连接池（**谨慎**，可能把压力转嫁到 DB）
- 降级非核心接口

#### Step 7：验证恢复

- `pending` 回到 0
- P99、错误率回落

### 面试话术

> pending > 0 说明请求在等连接而不是执行业务，是 DB 层饱和的直接信号，也是雪崩链路的早期环节。

---

## 4. SLI、SLO、SLA 的区别

### 概念

| 术语 | 英文 | 含义 | 例子 |
|------|------|------|------|
| **SLI** | Service Level Indicator | **测什么** — 可量化的服务指标 | 错误率、P99 延迟、可用性 |
| **SLO** | Service Level Objective | **目标是什么** — SLI 应达到的阈值 | 「P99 < 200ms」 |
| **SLA** | Service Level Agreement | **对外承诺** — 达不到有业务后果 | 「月可用性 99.9%，否则赔偿」 |

**关系：** SLI 是指标，SLO 是目标，SLA 是合同。SLO 通常比 SLA 略严，留出 buffer。

### 本实验（Phase 1）的 SLI / SLO

| SLI（测什么） | 计算方式 | 实验 SLO（目标） | 告警阈值（W2） |
|--------------|---------|-----------------|----------------|
| **可用性** | `up{job="device-report-service"}` | 99.9% 存活 | `up == 0` 持续 1m |
| **错误率** | 5xx / 总请求 | **< 1%** | **> 5%** 持续 2m |
| **延迟** | P99 响应时间 | **< 200ms** | **> 500ms** 持续 3m |
| **连接池** | `hikaricp_connections_pending` | **= 0** | **> 0** 持续 1m |

### 对应 PromQL

```promql
# SLI：错误率
sum(rate(http_server_requests_seconds_count{application="device-report-service", status=~"5.."}[5m]))
/ sum(rate(http_server_requests_seconds_count{application="device-report-service"}[5m]))

# SLI：P99 延迟
histogram_quantile(0.99,
  sum(rate(http_server_requests_seconds_bucket{application="device-report-service"}[5m])) by (le)
)

# SLI：可用性
up{job="device-report-service"}

# SLI：连接池等待
hikaricp_connections_pending{application="device-report-service"}
```

### 面试话术

> 我们 SLI 用 RED 方法：Rate、Errors、Duration，再加连接池饱和度。SLO 例如错误率低于 1%、P99 低于 200ms、可用性 99.9%。告警阈值比 SLO 宽松，例如错误率超 5% 才告警，避免抖动误报。

---

## 5. 告警太多怎么办？

### 原则

告警要少而准。避免 on-call 被刷屏（alert fatigue），导致真正 critical 的告警被忽略。

### 常见手段

| 手段 | 作用 |
|------|------|
| **分级** | critical / warning / info，走不同通知渠道 |
| **分组** | 按 `service`、`alertname`、业务模块聚合 |
| **抑制（inhibition）** | 例如 `up=0` 时抑制该服务的延迟、错误率告警 |
| **静默（silence）** | 发布窗口、计划内维护 |
| **提高 `for` 时长** | 如 P99 超 500ms **持续 3m** 才告警，过滤毛刺 |
| **合并通知** | 同类告警 5 分钟内只发一条 |
| **Runbook** | 告警描述中写「先看什么、怎么查」 |

### 分组示例

| 类别 | 示例告警 |
|------|---------|
| **业务** | device-report 错误率、上报 QPS 异常 |
| **组件** | PostgreSQL 连接池 pending、Kafka lag |
| **基础设施** | APISIX / Prometheus `up`、磁盘空间 |

### 本实验告警规则文件

路径：`iot-learn-lab/infra/prometheus/alert-rules-device-report.yml`

| 告警名 | 触发条件 |
|--------|---------|
| `DeviceReportServiceDown` | `up == 0` 持续 1m |
| `DeviceReportHighErrorRate` | 错误率 > 5% 持续 2m |
| `DeviceReportHighLatencyP99` | P99 > 500ms 持续 3m |
| `DeviceReportConnectionPoolExhausted` | `pending > 0` 持续 1m |

---

## 6. 黄金信号与 RED 方法（速查）

### Google 四大黄金信号

| 信号 | 含义 | 本实验对应 |
|------|------|-----------|
| **Latency** | 延迟 | P99、`http_server_requests_seconds_bucket` |
| **Traffic** | 流量 | QPS、`rate(http_server_requests_seconds_count)` |
| **Errors** | 错误 | 5xx 错误率 |
| **Saturation** | 饱和度 | HikariCP pending、JVM 堆使用率 |

### RED 方法（面向请求的服务）

| 维度 | 指标 |
|------|------|
| **Rate** | 请求速率 QPS |
| **Errors** | 错误率 |
| **Duration** | 延迟分布（P50/P95/P99） |

---

## 7. 学习场景与指标对照

| 场景 | 业务背景 | 关键指标 | 预期现象 |
|------|---------|---------|---------|
| **S1** 健康巡检 | 确认服务存活 | `up`、JVM 堆 | `up=1` |
| **S2** 流量突增 | 设备批量上报 | QPS、P99 | QPS 阶跃，P99 仍 < 200ms |
| **S3** 错误飙升 | 代码 bug / 异常 | 5xx 错误率 | 错误率 > 5%，触发告警 |
| **S4** 连接池压力 | DB 慢查询 | `pending`、P99 | `pending > 0`，P99 > 500ms |
| **S5** 告警验证 | 自动通知 | 4 条 alert rules | Firing → Inactive |
| **S6** APISIX | 网关入口 | `apisix_http_status` | Target UP，经 9080 转发成功 |

---

## 8. 自测 Checklist

- [ ] 能解释 P99 与平均值的区别
- [ ] 能说明错误率为何通常比 QPS 更紧急
- [ ] 能描述 `pending > 0` 的含义和 7 步排查顺序
- [ ] 能区分 SLI / SLO / SLA，并说出本实验 4 条 SLO
- [ ] 能列举告警降噪的至少 3 种手段
- [ ] Grafana Dashboard 4 行 Panel 均有数据
- [ ] 经 APISIX `:9080` 上报成功
- [ ] Prometheus 中 `device-report-service` 与 `apisix` Target 均为 UP

---

## 参考

- 设计文档：`docs/superpowers/specs/2026-07-02-ops-learning-plan-design.md`
- 实现计划：`docs/superpowers/plans/2026-07-02-phase1-observability.md`
- 实验脚本：`iot-learn-lab/scripts/scenario-s*.sh`
