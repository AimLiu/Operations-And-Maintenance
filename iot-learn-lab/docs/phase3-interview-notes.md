# Phase 3 面试复盘笔记（W5–W6）

> 操作步骤见：`phase3-scenarios-runbook.md`

## 场景记录

| 场景 | 日期 | 通过？ | 关键现象 | 截图/链接 |
|------|------|--------|----------|-----------|
| R1 Feign 基准 | | ☐ | 双服务 201，ackId 正常 | |
| R2 Sentinel 限流 | | ☐ | Block QPS > 0，dispatch ≤5 QPS | |
| R3 Nacos 热更新 | | ☐ | count 5→20 后 block 减少 | |
| R4 雪崩无熔断 | | ☐ | P99 高，线程升，响应慢 | |
| R5 雪崩有熔断 | | ☐ | P99 低，DEGRADED/fallback | |
| R6 Redis 降级 | | ☐ | source=redis-cache | |

## R4 vs R5 对比（面试重点）

| 指标 | R4（无保护） | R5（degrade+fallback） |
|------|-------------|------------------------|
| dispatch 状态 | DOWN | DOWN |
| device-report P99 | | |
| jvm_threads_live | | |
| 典型 HTTP | | |
| 典型响应体 | | |

**Prometheus 对比查询（R4/R5 压测期间）：**

```promql
histogram_quantile(0.99,
  sum(rate(http_server_requests_seconds_bucket{
    application="device-report-service",
    uri="/api/v1/devices/{deviceId}/reports-with-dispatch"
  }[1m])) by (le)
)

jvm_threads_live_threads{application="device-report-service"}

sum(rate(http_server_requests_seconds_count{application="command-dispatch-service"}[1m]))
```

## 面试题自测

1. 限流放网关还是应用？本实验 R2 对应哪一层？
2. Sentinel flow vs degrade 区别？
3. api-breaker(503) vs Sentinel degrade vs 网关 504 timeout 区别？
4. 雪崩怎么一步步发生？R4/R5 对照说明了什么？
5. Feign fallback 与 Sentinel fallback 分别在哪一层生效？
6. Hystrix 和 Sentinel 区别？为何选 Sentinel？
7. Nacos 持久化 Sentinel 规则的好处？

## 自由笔记

（实验过程中的现象、踩坑、参数调整记录）
