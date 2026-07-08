# Phase 3 场景操作手册（R1–R6）

> **适用场景：** W5–W6 应用层韧性实验（Feign + Sentinel + Nacos + Redis）  
> **环境：** Windows 运行 Java 双服务；WSL Docker 运行 Nacos / Redis / PostgreSQL / Sentinel Dashboard / Prometheus / Grafana

**相关文档：**

- 实施计划：`docs/superpowers/plans/2026-07-05-phase3-application-resilience.md`
- Phase 2 网关指标：`iot-learn-lab/docs/phase2-apisix-prometheus-setup.md`
- Nacos 规则模板：`iot-learn-lab/infra/sentinel/`

---

## 一、实验前准备

### 1.1 服务与端口

| 组件 | 运行位置 | 地址 |
|------|----------|------|
| device-report-service | Windows IDEA | `http://localhost:8765` |
| command-dispatch-service | Windows IDEA | `http://localhost:8767` |
| Nacos | WSL Docker | `http://192.168.19.64:8848/nacos` |
| Sentinel Dashboard | WSL Docker | `http://192.168.19.64:8858`（sentinel/sentinel） |
| Redis | WSL Docker | `192.168.19.64:6379` |
| Prometheus | WSL Docker | `http://192.168.19.64:9090` |
| Grafana | WSL Docker | `http://192.168.19.64:3000` |

**网络口诀：** Java 调 Java 用 `localhost`；Java 调 Docker 用 `192.168.19.64`；WSL 脚本压 Windows 应用用 `192.168.16.1:8765`。

### 1.2 Nacos 规则（必须先配好）

在 Nacos **配置管理** 中创建两条 JSON 配置（Group 均为 `SENTINEL_GROUP`）：

| Data ID | 用途 | 模板文件 |
|---------|------|----------|
| `device-report-service-flow-rules` | R2/R3 限流 | `infra/sentinel/nacos-flow-rules-device-report.json` |
| `device-report-service-degrade-rules` | R5 熔断 | `infra/sentinel/device-report-service-degrade-rules.json` |

> **注意：** Nacos 里放的是 **JSON 规则数组**，不是 `application.yml` 的 datasource 配置。

### 1.3 WSL 脚本环境

```bash
cd iot-learn-lab/scripts/phase3
chmod +x *.sh

# 运行前按需 export（各脚本内置默认值，可覆盖）
export DIRECT_URL=http://192.168.16.1:8765
export DISPATCH_URL=http://192.168.16.1:8767
export REDIS_HOST=192.168.19.64
```

> `scripts/basic-path-config.sh` 为个人备忘，Phase 3 脚本**不引用**该文件；各脚本独立使用 `${DIRECT_URL:-默认值}` 形式。

### 1.4 脚本索引

| 场景 | 脚本 | 时长（默认） |
|------|------|-------------|
| R1 Feign 基准 | `scenario-r1-feign-baseline.sh` | ~10s |
| R2 Sentinel 限流 | `scenario-r2-sentinel-flow-block.sh` | 60s |
| R3 Nacos 热更新 | `scenario-r3-nacos-hot-reload.sh` | 交互式 |
| R4 雪崩（无熔断） | `scenario-r4-avalanche-no-breaker.sh` | 60s |
| R5 雪崩（有熔断） | `scenario-r5-avalanche-with-breaker.sh` | 60s |
| R6 Redis 降级 | `scenario-r6-redis-fallback.sh` | 交互式 |

### 1.5 Prometheus 抓取目标

Phase 3 需两个 Spring Boot Target 均为 UP（`http://192.168.19.64:9090/targets`）：

| Job | Target | 检查 |
|-----|--------|------|
| device-report-service | `192.168.16.1:8765` | `up{job="device-report-service"}` |
| command-dispatch-service | `192.168.16.1:8767` | `up{job="command-dispatch-service"}` |

> R1/R2/R5 需观测 dispatch QPS，请在 Prometheus 增加 8767 抓取（参考 `infra/prometheus/scrape-device-report.yml` 追加 `command-dispatch-service` job）。

---

## 二、通用观测方式

### 2.1 curl 单次验证

```bash
curl -s -X POST "http://192.168.16.1:8765/api/v1/devices/test-dev/reports-with-dispatch" \
  -H "Content-Type: application/json" \
  -d '{"payload":{"temperature":25}}' | jq .
```

成功时 HTTP **201**，响应结构：

```json
{
  "reportResponse": { "reportId": "...", "deviceId": "...", ... },
  "ackResponse": { "ackId": "...", "deviceId": "...", "result": "OK", "success": true }
}
```

### 2.2 Sentinel Dashboard

1. 打开 `http://192.168.19.64:8858`，登录 `sentinel` / `sentinel`
2. **机器列表** → 点击 `device-report-service`
3. 查看：
   - **实时监控** → 资源 `dispatchAck` 的通过 QPS / Block QPS / RT
   - **流控规则** → `dispatchAck` 阈值
   - **降级规则** → degrade 配置（R5）

### 2.3 Grafana / Prometheus（通用 PromQL）

Prometheus 即时查询：`http://192.168.19.64:9090/graph`

**存活：**

```promql
up{job="device-report-service"}
up{job="command-dispatch-service"}
```

**Feign 链路 QPS（Phase 3 核心接口）：**

```promql
# 上游 reports-with-dispatch 入口
sum(rate(http_server_requests_seconds_count{
  application="device-report-service",
  uri="/api/v1/devices/{deviceId}/reports-with-dispatch"
}[1m]))

# 下游 dispatch 全服务
sum(rate(http_server_requests_seconds_count{
  application="command-dispatch-service"
}[1m]))
```

**延迟与线程（R4/R5 雪崩对比常用）：**

```promql
# 链路 P99
histogram_quantile(0.99,
  sum(rate(http_server_requests_seconds_bucket{
    application="device-report-service",
    uri="/api/v1/devices/{deviceId}/reports-with-dispatch"
  }[1m])) by (le)
)

# 活跃线程
jvm_threads_live_threads{application="device-report-service"}
```

**错误率：**

```promql
sum(rate(http_server_requests_seconds_count{
  application="device-report-service", status=~"5.."
}[1m]))
```

> **Sentinel Block QPS** 当前无专用 PromQL，用 HTTP **429** rate 或 Sentinel Dashboard 观测（见各场景章节）。

**label 对不上时排查：**

```promql
count by (uri) (http_server_requests_seconds_count{application="device-report-service"})
count by (status) (http_server_requests_seconds_count{
  application="device-report-service",
  uri="/api/v1/devices/{deviceId}/reports-with-dispatch"
})
```

### 2.4 应用日志

- device-report：`iot-learn-lab/device-report-service/log/`
- command-dispatch：`iot-learn-lab/command-dispatch-service/log/`

---

## 三、场景 R1：Feign 链路基准线

**目标：** 验证双服务联通，上报落库 + Feign 调用 dispatch 均正常。

### 操作步骤

1. IDEA 启动 `DeviceReportApplication`（8765）和 `CommandDispatchApplication`（8767）
2. WSL 执行：

```bash
./scenario-r1-feign-baseline.sh
```

### 如何看结果

| 检查项 | 预期 | 在哪里看 |
|--------|------|----------|
| 健康检查 | 两个 `/actuator/health` 均为 UP | 脚本输出 |
| HTTP 状态码 | 每次 **201** | 脚本 `HTTP 201` |
| 响应体 | 含 `reportId`、`ackResponse.ackId` | 脚本 JSON 输出 |
| 下游 QPS | dispatch 与 report 同步有流量 | Grafana / Prometheus |
| Sentinel | `dispatchAck` 有通过 QPS，无 Block | Dashboard 实时监控 |

### Prometheus 观测

```promql
# 双服务均 UP
up{job="device-report-service"} == 1
up{job="command-dispatch-service"} == 1

# 压测后上游 / 下游 QPS 应同步 > 0
sum(rate(http_server_requests_seconds_count{
  application="device-report-service",
  uri="/api/v1/devices/{deviceId}/reports-with-dispatch"
}[1m]))

sum(rate(http_server_requests_seconds_count{
  application="command-dispatch-service"
}[1m]))

# 链路 P99 正常（无尖峰）
histogram_quantile(0.99,
  sum(rate(http_server_requests_seconds_bucket{
    application="device-report-service",
    uri="/api/v1/devices/{deviceId}/reports-with-dispatch"
  }[1m])) by (le)
)
```

---

## 四、场景 R2：Sentinel 流控 block

**目标：** Nacos flow 规则 `dispatchAck` QPS=5 生效，超出部分被 block。

### 前置条件

- [x] Nacos 已发布 `device-report-service-flow-rules`（`count: 5`）
- [x] `device-report-service` 已重启并加载规则
- [x] `command-dispatch-service` **运行中**
- [x] Sentinel Dashboard 已启动

### 操作步骤

```bash
./scenario-r2-sentinel-flow-block.sh
# 可选：DURATION=30 CONCURRENCY=15 ./scenario-r2-sentinel-flow-block.sh
```

### 如何看结果

| 检查项 | 预期 | 在哪里看 |
|--------|------|----------|
| HTTP 统计 | 大量 **429**（Sentinel block）；**201** 约 ≤5/s | 脚本末尾统计 |
| Block QPS | > 0 | Dashboard → dispatchAck |
| dispatch QPS | 被压在 ~5 | Prometheus dispatch QPS |
| 面试要点 | 网关限流 vs 应用限流：R2 是 **L3 Sentinel** 细粒度保护 | — |

### Prometheus 观测

```promql
# 入口总 QPS（压测期间应较高）
sum(rate(http_server_requests_seconds_count{
  application="device-report-service",
  uri="/api/v1/devices/{deviceId}/reports-with-dispatch"
}[1m]))

# 通过限流的 201 QPS（应约 ≤ 5/s）
sum(rate(http_server_requests_seconds_count{
  application="device-report-service",
  uri="/api/v1/devices/{deviceId}/reports-with-dispatch",
  status="201"
}[1m]))

# Sentinel block → HTTP 429 QPS（应 > 0）
sum(rate(http_server_requests_seconds_count{
  application="device-report-service",
  uri="/api/v1/devices/{deviceId}/reports-with-dispatch",
  status="429"
}[1m]))

# 下游被保护：dispatch QPS 约 ≤ 5
sum(rate(http_server_requests_seconds_count{
  application="command-dispatch-service"
}[1m]))
```

> Block QPS 也可在 Sentinel Dashboard → `dispatchAck` 查看；当前项目未接入 Sentinel 专用 actuator 指标。

> 若全是 201：检查 Nacos JSON 格式、命名空间是否与 `application.yml` 一致、`sentinel-datasource-nacos` 依赖是否已加。

---

## 五、场景 R3：Nacos 规则热更新

**目标：** 不重启 JVM，修改 Nacos 限流阈值后规则立即生效。

### 操作步骤

```bash
./scenario-r3-nacos-hot-reload.sh
```

脚本分三阶段：

1. **阶段 A**：QPS=5 时压测 30s（等同 R2）
2. **阶段 B**：在 Nacos 将 `count` 从 `5` 改为 `20`，发布
3. **阶段 C**：再次压测 30s

Nacos 修改路径：**配置管理** → `device-report-service-flow-rules` → 编辑 → 改 `"count": 20` → 发布。

### 如何看结果

| 检查项 | 阶段 A（QPS=5） | 阶段 B（QPS=20） |
|--------|----------------|-----------------|
| 201 比例 | 低 | **明显升高** |
| 429/block | 多 | **减少** |
| JVM 重启 | 不需要 | 不需要 |

对比文件：`/tmp/r3-phase-a.log` vs `/tmp/r3-phase-b.log`

Dashboard：**流控规则** 中阈值应变为 20（可能有数秒延迟）。

### Prometheus 观测

对比阶段 A / B，复用 R2 语句，重点看 **201** 与 **429** 比例变化：

```promql
# 201 通过 QPS（阶段 B 应明显高于阶段 A）
sum(rate(http_server_requests_seconds_count{
  application="device-report-service",
  uri="/api/v1/devices/{deviceId}/reports-with-dispatch",
  status="201"
}[1m]))

# 429 block QPS（阶段 B 应明显低于阶段 A）
sum(rate(http_server_requests_seconds_count{
  application="device-report-service",
  uri="/api/v1/devices/{deviceId}/reports-with-dispatch",
  status="429"
}[1m]))

# 429 占比
sum(rate(http_server_requests_seconds_count{
  application="device-report-service",
  uri="/api/v1/devices/{deviceId}/reports-with-dispatch",
  status="429"
}[1m]))
/
sum(rate(http_server_requests_seconds_count{
  application="device-report-service",
  uri="/api/v1/devices/{deviceId}/reports-with-dispatch"
}[1m]))
```

---

## 六、场景 R4：雪崩 — 无熔断（对照组）★

**目标：** 下游挂掉 + 无保护时，上游线程阻塞、P99 恶化（坏现象）。

### 前置条件（重要）

| 步骤 | 操作 |
|------|------|
| 1 | Nacos **删除或清空** `device-report-service-degrade-rules` |
| 2 | `application.yml` 设 `feign.sentinel.enabled: false`（临时） |
| 3 | `CommandDispatchClient` **临时去掉** `fallback = DispatchFallbackHandler.class` |
| 4 | 配置 Feign 超时（便于观察等待）：`connectTimeout: 3000`, `readTimeout: 10000` |
| 5 | IDEA **Stop** `command-dispatch-service` |

> **说明：** 若保留 Feign fallback，连接失败会立刻走降级，**看不到雪崩**。R4 必须去掉 fallback 才能体现「同步调用拖垮上游」。

### 操作步骤

```bash
./scenario-r4-avalanche-no-breaker.sh
```

### 如何看结果

| 检查项 | 预期（坏现象） | 在哪里看 |
|--------|---------------|----------|
| `time_total` | 接近 **3~10s**（Feign 超时） | 脚本耗时统计 |
| HTTP | 可能 **500** 或超时 | 脚本状态码统计 |
| P99 | **持续升高** | Grafana report P99 |
| 线程 | `jvm_threads_live` **上升** | Grafana / Prometheus |
| dispatch | Target **DOWN**，QPS ≈ 0 | Prometheus targets |

**截图存档：** Grafana P99 + 线程面板，写入 `phase3-interview-notes.md`。

### Prometheus 观测

```promql
# dispatch 已 Stop → Target DOWN
up{job="command-dispatch-service"} == 0

# 上游 QPS 仍可能较高（坏现象：还在接请求）
sum(rate(http_server_requests_seconds_count{
  application="device-report-service",
  uri="/api/v1/devices/{deviceId}/reports-with-dispatch"
}[1m]))

# P99 显著升高（接近 Feign readTimeout）
histogram_quantile(0.99,
  sum(rate(http_server_requests_seconds_bucket{
    application="device-report-service",
    uri="/api/v1/devices/{deviceId}/reports-with-dispatch"
  }[1m])) by (le)
)

# 活跃线程上升
jvm_threads_live_threads{application="device-report-service"}

# 5xx 可能升高
sum(rate(http_server_requests_seconds_count{
  application="device-report-service",
  uri="/api/v1/devices/{deviceId}/reports-with-dispatch",
  status=~"5.."
}[1m]))
```

---

## 七、场景 R5：雪崩 — Sentinel 熔断 + fallback（保护组）★

**目标：** 同样下游不可用，但有 degrade + fallback 时快速失败（好现象）。

### 前置条件

| 步骤 | 操作 |
|------|------|
| 1 | Nacos **恢复** `device-report-service-degrade-rules` |
| 2 | `feign.sentinel.enabled: true` |
| 3 | `CommandDispatchClient` **恢复** `fallback = DispatchFallbackHandler.class` |
| 4 | `command-dispatch-service` 保持 **Stop** |

### 操作步骤

```bash
./scenario-r5-avalanche-with-breaker.sh
```

### 如何看结果

| 检查项 | 预期（好现象） | 在哪里看 |
|--------|---------------|----------|
| HTTP | 多为 **201** | 脚本统计 |
| 响应体 | `ackResponse.result` = **DEGRADED** 或 `ackId` 以 `fallback-` 开头 | 脚本采样 JSON |
| `time_total` | **毫秒~百毫秒级**，远小于 R4 | 脚本耗时统计 |
| P99 | **保持低位** | Grafana |
| dispatch QPS | ≈ 0 | Prometheus |

**与 R4 并排对比截图** 是面试核心材料。

### Prometheus 观测

与 R4 使用**相同 PromQL**，对比数值差异：

```promql
# dispatch DOWN
up{job="command-dispatch-service"} == 0

# 上游 QPS 可仍高，但 P99 保持低位（好现象）
histogram_quantile(0.99,
  sum(rate(http_server_requests_seconds_bucket{
    application="device-report-service",
    uri="/api/v1/devices/{deviceId}/reports-with-dispatch"
  }[1m])) by (le)
)

# 线程相对稳定
jvm_threads_live_threads{application="device-report-service"}

# 不再打挂掉的下游
sum(rate(http_server_requests_seconds_count{
  application="command-dispatch-service"
}[1m]))

# 多为 201，5xx 低
sum(rate(http_server_requests_seconds_count{
  application="device-report-service",
  uri="/api/v1/devices/{deviceId}/reports-with-dispatch",
  status="201"
}[1m]))
```

| 指标 | R4（坏） | R5（好） |
|------|----------|----------|
| P99 | 高 | 低 |
| `jvm_threads_live` | 可能飙升 | 相对稳定 |
| dispatch QPS | 可能有连接尝试 | ≈ 0 |

---

## 八、场景 R6：Redis 降级兜底

**目标：** dispatch 不可用时，返回该 `deviceId` 最近一次成功的 ACK 缓存。

### 前置条件

> **当前状态：** Redis 降级逻辑属于 Phase 3 **Task 13**，若代码尚未实现，脚本可用于验收清单，响应仍为 R5 式静态 fallback。

- [ ] `spring-boot-starter-data-redis` 已接入
- [ ] `spring.data.redis.host: 192.168.19.64`
- [ ] 成功 dispatch 后写入 `dispatch:ack:{deviceId}`
- [ ] Fallback 命中缓存时返回 `source: redis-cache`

### 操作步骤

```bash
./scenario-r6-redis-fallback.sh
```

1. dispatch **运行**，对同一 `deviceId` 预热 5 次
2. **Stop** dispatch
3. 再次请求同一 `deviceId`

### 如何看结果

| 检查项 | 预期 | 在哪里看 |
|--------|------|----------|
| 响应 JSON | 含 **`source: redis-cache`** | curl / 脚本输出 |
| 与 R5 区别 | ackId 为真实历史值，非 `fallback-uuid` | 响应体对比 |
| Redis | key 存在 | `redis-cli -h 192.168.19.64 GET dispatch:ack:r6-device-1` |

### Prometheus 观测

Redis 命中**无法**直接用 PromQL 观测，可用以下语句辅助：

```promql
# 请求仍成功返回时 QPS 正常
sum(rate(http_server_requests_seconds_count{
  application="device-report-service",
  uri="/api/v1/devices/{deviceId}/reports-with-dispatch",
  status="201"
}[1m]))

# 响应快（缓存命中，类似 R5）
histogram_quantile(0.99,
  sum(rate(http_server_requests_seconds_bucket{
    application="device-report-service",
    uri="/api/v1/devices/{deviceId}/reports-with-dispatch"
  }[1m])) by (le)
)

# dispatch DOWN 时下游 QPS 应为 0
sum(rate(http_server_requests_seconds_count{
  application="command-dispatch-service"
}[1m]))
```

最终验收以响应体 `source: redis-cache` 和 `redis-cli GET dispatch:ack:{deviceId}` 为准。

---

## 九、场景对照速查表

| 场景 | 下游 dispatch | 保护机制 | 预期 P99 | 预期响应 |
|------|--------------|----------|----------|----------|
| R1 | UP | 无 | 正常 | 201 + OK |
| R2 | UP | flow QPS=5 | 正常 | 201 + 429 混合 |
| R3 | UP | flow 热更新 | 随阈值变化 | block 比例变化 |
| R4 | DOWN | **无** fallback/degrade | **高** | 慢/500 |
| R5 | DOWN | degrade + fallback | **低** | 201 + DEGRADED |
| R6 | DOWN | Redis 缓存 | 低 | 201 + redis-cache |

---

## 十、常见问题

### Q1：R2 没有 429，全是 201？或出现大量 500？

**500 + `FlowException`：** 限流已生效，但缺少 `blockHandler`。`@SentinelResource` 的 `fallback` **不处理**流控 block，需单独配置 `blockHandler` 并返回 429。

修复后预期：**201**（通过）+ **429**（block），不再出现 500。

若仍全是 201：

1. Nacos 配置是否为 **JSON 数组**（不是 YAML datasource）
2. 命名空间是否与 `application.yml` 一致（默认 `public`）
3. `pom.xml` 是否有 `sentinel-datasource-nacos` 依赖
4. Dashboard 流控规则是否出现 `dispatchAck`

### Q2：R4 响应也很快，没有雪崩？

Feign **fallback 未去掉**。对照组必须禁用 `DispatchFallbackHandler`。

### Q3：Dashboard 一直刷 `Find sentinel dashboard server list`？

INFO 级别日志，不影响运行。未启动 Dashboard 时可忽略，或启动 `infra/sentinel/docker-compose-sentinel-dashboard.yml`。

### Q4：Phase 3 要不要走 APISIX 网关？

R2–R5 建议 **直连** `192.168.16.1:8765`，避免 Phase 2 网关限流与 Sentinel 叠层干扰。R1 可用直连验证。

---

## 十一、复盘模板

实验完成后填写 `iot-learn-lab/docs/phase3-interview-notes.md`，至少包含：

- R4 / R5 Grafana P99 对比截图
- 「雪崩怎么一步步发生？」
- 「APISIX api-breaker(503) vs Sentinel degrade vs 网关 504 的区别」
