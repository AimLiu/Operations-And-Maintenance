# Stage 2 W8 前置知识：分布式追踪与 Jaeger

**读者：** 已完成 W7（Rollouts / 金丝雀），三服务在 minikube 可调；熟悉 Prometheus 指标，但还没有跨服务 Trace  
**范围：** Stage 2 W8（Micrometer Tracing → OTLP → Jaeger；HTTP / Feign / Kafka 观察）  
**对照计划：** `docs/superpowers/plans/2026-07-23-stage2-w8-jaeger.md`  
**不讲：** CI/CD（W9–W10）；Service Mesh 自动注入；Tempo / 多后端

读完你应能回答这些事：

1. Metrics / Logs / Traces 各解决什么问题  
2. Trace、Span、traceId 是什么关系  
3. **Jaeger 是做什么的、有哪些特性、一般怎么配**  
4. **OTLP 是什么、和 Jaeger / 应用各处在什么位置**  
5. 为什么选 Micrometer Tracing + OTel，而不是手写 Zipkin 客户端  
6. 采样率 `probability` 在学习环境与生产的差别  
7. Feign 跨服务如何「串」成一棵树；Kafka 为何更容易断  
8. 混合架构下 Pod 如何把 trace 打到 Docker 里的 Jaeger  

---

## 1. 先看一串你马上要敲的命令

```bash
# Jaeger（WSL Docker）
cd iot-learn-lab/infra/jaeger
docker compose -f docker-compose-jaeger.yml up -d
# UI: http://127.0.0.1:16686 或 http://<WSL-IP>:16686

# 打一条带 Feign 的请求（Ingress）
curl -s -H "Host: device-report.iot-learn.local" \
  -X POST "http://$(minikube ip)/api/v1/devices/w8-demo/reports-with-dispatch" \
  -H "Content-Type: application/json" \
  -d '{"payload":{"temp":1,"source":"w8"}}'

# 场景脚本（实现后）
iot-learn-lab/scripts/stage2/scenario-k8-jaeger-trace.sh
```

成功时：Jaeger → Service 下拉能看到 `device-report-service` / `command-dispatch-service`，点开一条 trace 能看到父子 span。

---

## 2. 和 W3 / W7 对比

| 以前 | W8 |
|------|-----|
| Prometheus：QPS、错误率、延迟直方图 | **一次请求**在多服务上的耗时树 |
| Rollouts Analysis：聚合指标决策发布 | Trace：**定位**慢在哪一跳、哪次 Feign |
| `kubectl logs`：单 Pod 文本 | Trace：跨 Pod 用同一 `traceId` 关联 |

口诀：

> **Metrics 告诉你「坏了」；Traces 告诉你「坏在哪一跳」；Logs 告诉你「那一跳里发生了什么」。**

---

## 3. Trace / Span 一分钟

```text
Trace（一次请求的完整旅程）
  └── Span: ingress→report HTTP server
        ├── Span: Feign client → dispatch
        │     └── Span: dispatch HTTP server
        └── Span: Kafka send（若开启）
              └── Span: consumer process（另一进程，靠消息头续上）
```

| 概念 | 含义 |
|------|------|
| **traceId** | 整次调用唯一 ID，日志里也可打印便于对照 |
| **spanId** | 当前这一步 |
| **parent** | 谁触发了这一步 → UI 里画成树 |

---

## 4. Jaeger 是做什么的？

**Jaeger**（发音近 “yay-ger”）是开源的 **分布式追踪后端 + UI**，用来：

1. **接收**各服务上报的 Span / Trace  
2. **存储**（本 lab：all-in-one + Badger 挂 `./data`；生产可接 Elasticsearch / Cassandra 等）  
3. **查询与可视化**：按服务名、操作名、耗时、标签过滤，画出一次请求的调用树  

一句话：

> **应用负责「造 span」；Jaeger 负责「收、存、查、画」。**

没有 Jaeger（或同类后端），应用就算生成了 trace，你也没有地方打开那棵树。

### 4.1 常见特性（学习阶段够用）

| 特性 | 说明 |
|------|------|
| **Trace 查询 UI** | 按 Service / Operation / Tags / 耗时范围检索 |
| **调用树 / 火焰图式时间线** | 看哪一跳慢、哪一跳报错 |
| **多服务聚合** | 同一 `traceId` 下拼齐 report、dispatch、consumer |
| **多种接收协议** | 现代推荐 **OTLP**；也兼容历史 Jaeger/Zipkin 协议 |
| **采样与降载** | 可与客户端采样配合；生产避免全量 |
| **all-in-one** | 单容器集成 Collector + Query + UI；本 lab 用 Badger 落盘，适合小机器 |
| **与 Prometheus 分工** | Prom 看聚合指标；Jaeger 看单次请求路径（互补，不替代） |

### 4.2 组件怎么理解（all-in-one 里都在一个进程）

```text
Agent/Exporter（在应用里）──OTLP──► Collector ──► Storage
                                              │
Query API / UI ◄──────────────────────────────┘
```

W8 用 `jaegertracing/all-in-one`：**Collector + Query + UI** 打成一个 Docker 容器，不必先学生产级拆分。

### 4.3 一般如何配置？

分三层：**Jaeger 自身**、**网络暴露**、**应用侧导出**。

**（1）Jaeger 自身（Docker）**

完整文件：`iot-learn-lab/infra/jaeger/docker-compose-jaeger.yml`（可复制到 WSL 后自行 `up`）。

```yaml
# 要点摘录；完整见仓库 compose
name: iot-learn-jaeger
services:
  jaeger:
    image: jaegertracing/all-in-one:1.76.0   # 1.x 末代；比 2.x 省配置/更轻
    container_name: jaeger-learn
    environment:
      COLLECTOR_OTLP_ENABLED: "true"
      SPAN_STORAGE_TYPE: badger
      BADGER_EPHEMERAL: "false"
      BADGER_DIRECTORY_VALUE: /badger/data
      BADGER_DIRECTORY_KEY: /badger/key
      BADGER_SPAN_STORE_TTL: 72h
    ports:
      - "16686:16686"   # UI
      - "4317:4317"     # OTLP gRPC
      - "4318:4318"     # OTLP HTTP（本 lab 优先）
      - "14269:14269"   # admin / health
    volumes:
      - ./data:/badger  # 与 compose 同级 data/
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1:14269/ || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 5
      start_period: 20s
    deploy:
      resources:
        limits: { cpus: "0.50", memory: 512M }
    networks:
      - jaeger-network
networks:
  jaeger-network:
    name: iot-learn-jaeger
    driver: bridge
```

常用环境变量 / 点：

| 配置 | 作用 |
|------|------|
| `COLLECTOR_OTLP_ENABLED=true` | 允许应用用 OTLP 推送 |
| `SPAN_STORAGE_TYPE=badger` + `./data` | 本地持久化；重启不丢 lab 数据 |
| `BADGER_SPAN_STORE_TTL` | 保留时长，控制磁盘 |
| 端口 `16686` | 浏览器打开 UI |
| 端口 `4317` / `4318` | 应用导出地址（gRPC / HTTP） |
| 端口 `14269` | admin 健康检查 `/` |
| 网络 `iot-learn-jaeger` | 专用网；不并入 Prometheus/Kafka（Pod 走宿主机端口） |

生产还会配：ES/Cassandra、副本、鉴权、采样策略下沉到 Collector 等——W8 不做。

**（2）网络（混合架构）**

| 谁访问谁 | 地址示例 |
|----------|----------|
| 你看 UI | `http://127.0.0.1:16686` 或 `http://<WSL-IP>:16686` |
| minikube Pod 推送 | `http://host.minikube.internal:4318/v1/traces` |
| IDEA 本机调试 | `http://127.0.0.1:4318/v1/traces` |

**（3）应用侧（Spring Boot 3，示意）**

```yaml
management:
  tracing:
    sampling:
      probability: 1.0          # lab 全采样；生产下调
  otlp:
    tracing:
      endpoint: http://host.minikube.internal:4318/v1/traces
```

依赖：`micrometer-tracing-bridge-otel` + `opentelemetry-exporter-otlp`。  
具体属性名以 Boot 3.3 文档为准；Helm ConfigMap 用环境变量注入同一 endpoint。

**配置检查清单：**

1. Jaeger 容器 Running，UI 能开  
2. `4318` 从 Pod 网可达  
3. 应用采样 > 0，endpoint 指对  
4. 镜像已含 tracing 依赖并滚动更新  

---

## 5. OTLP 是什么？

**OTLP** = **OpenTelemetry Protocol**（OpenTelemetry 的标准传输协议）。

它规定：客户端（应用 / SDK）如何把 **Traces、Metrics、Logs** 编码并发送到 Collector / 后端。

对本 lab：

```text
Spring 里生成的 Span
    → OTel SDK / Micrometer bridge 编码成 OTLP
    → HTTP POST ...:4318/v1/traces   （或 gRPC :4317）
    → Jaeger Collector 解码入库
    → 你在 UI 里看见
```

### 5.1 为什么需要 OTLP？

| 没有统一协议时 | 有 OTLP 后 |
|----------------|------------|
| 应用绑死 Zipkin / Jaeger 私有格式 | 应用只依赖 **OTel/OTLP** |
| 换后端要改客户端 | 后端换成 Jaeger / Tempo / 云厂商 Collector，客户端常不变 |
| 每家一套 SDK | CNCF 生态默认「出口」 |

口诀：

> **OpenTelemetry 是「仪表与语义」；OTLP 是「怎么把数据运出去」；Jaeger 是「运到哪以后怎么查」。**

### 5.2 OTLP 与 Jaeger 的分工

| 名称 | 角色 |
|------|------|
| **Micrometer Tracing** | Spring 侧「何时打点」 |
| **OTel bridge + exporter** | 把点变成 OTLP 并发送 |
| **OTLP** | 线路上的标准报文 |
| **Jaeger** | 接收（Collector）+ 存储 + UI |

本 lab **不**再单独部署 Zipkin；Jaeger 开 OTLP 即可。

### 5.3 HTTP 还是 gRPC？

| | 端口（惯例） | 本 lab |
|--|--------------|--------|
| OTLP/HTTP | `4318`，路径常含 `/v1/traces` | **优先**（curl 易测、防火墙友好） |
| OTLP/gRPC | `4317` | 可选；性能更好，排障稍绕 |

应用配置里 endpoint 要与协议一致（HTTP 不要误写成只开了 gRPC 的地址）。

### 5.4 和 Prometheus 拉取模型对比

| | Prometheus | OTLP → Jaeger |
|--|------------|----------------|
| 方向 | 服务端 **拉** `/actuator/prometheus` | 应用 **推** 到 Collector |
| 金丝雀时 | 单 NodePort 易只看到一个 Pod | **每个 Pod 各自推送**，更容易收齐 |
| 看什么 | 聚合计数 / 速率 | 单次请求树 |

这也能解释：W7 Analysis 吃 Prom 会「片面」；W8 Trace 走 OTLP 推送，问题模型不同。

---

## 6. Spring Boot 3 官方路线（本 lab 选型）

```text
业务代码（MVC / Feign / Kafka）
    → Micrometer Observation / Tracing API
    → micrometer-tracing-bridge-otel
    → OTLP exporter
    → Jaeger Collector
    → Jaeger UI
```

不单独再部署 Zipkin；Jaeger 开 `COLLECTOR_OTLP_ENABLED` 直接收 OTLP。

学习环境：

```yaml
management.tracing.sampling.probability: 1.0
```

生产常降到 `0.01`～`0.1`，否则存储与开销爆炸。

---

## 7. 混合架构：Pod → Docker Jaeger

与 Prometheus 类似，Jaeger 放 WSL Docker，避免再往 minikube 塞一套存储：

```text
Pod 内 endpoint:
  http://host.minikube.internal:4318/v1/traces
        │
        ▼
WSL 宿主机 :4318 → jaeger-learn 容器
UI :16686
```

排障顺序：

1. 本机浏览器能否打开 UI  
2. 临时 Pod `curl host.minikube.internal:4318` 是否通  
3. 应用 env 是否带上 endpoint、采样是否为 1.0  
4. 是否用了**含新依赖的镜像**（只改 yml 不 rebuild 不够）

**重建三镜像并 load（Task 4 Step 1 详版）：**  
见计划 `docs/superpowers/plans/2026-07-23-stage2-w8-jaeger.md` → Task 4 → Step 1。  
同 tag 时推荐 **做法 A**：先停 Argo CD Application `iot-learn-lab` 的 AUTO-SYNC → `scale` Rollout/Deployment 到 0 → `minikube image rm/load` → 再打开 sync。  
速查：`iot-learn-lab/docs/stage2-helm-cheatsheet.md`「同 tag 换镜像」。

---

## 8. Feign vs Kafka（面试高频）

| | HTTP / Feign | Kafka |
|--|--------------|-------|
| 传播介质 | HTTP 头（W3C Trace Context） | 消息 headers（需 instrumentation） |
| 默认难度 | 相对容易自动串 | 更容易「两截 trace」 |
| 本 lab | 结业必看通 | 尽力；不通则记入 runbook |

---

## 9. 和 W7 Analysis 的关系（避免混淆）

W7 用 Prometheus **错误率**决定是否 abort；W8 用 Trace **解释**一次失败慢在哪。

W7 讲过：单 NodePort scrape 导致 `version=v2` 指标片面——那是 **Metrics 采集拓扑**问题。  
W8 的 OTLP 是应用 **主动推送**，每个 Pod 自己往 Jaeger 送 span，**不依赖** NodePort 轮询刮指标。因此 Trace 反而更容易在金丝雀阶段同时看到 v1/v2 服务名（若 `spring.application.name` / resource attributes 区分得当）。

---

## 10. W8 故意还没碰的东西

| 主题 | 放到 |
|------|------|
| GitHub Actions 构建推送 | W9 |
| CI 改 `image.tag` + Argo Sync | W10 |
| Ingress / APISIX 接入 span | 选修 |
| 按 Pod 修好 Prom scrape | 选修（可与 W7 对照笔记） |

---

## 11. 建议阅读顺序

1. 本文（尤其 §4 Jaeger、§5 OTLP）  
2. 计划 `docs/superpowers/plans/2026-07-23-stage2-w8-jaeger.md` Task 1→4  
3. [Spring Boot Tracing](https://docs.spring.io/spring-boot/reference/actuator/micrometer-tracing.html)  
4. [Jaeger Getting Started](https://www.jaegertracing.io/docs/latest/getting-started/)  
5. [OTLP 规范概览](https://opentelemetry.io/docs/specs/otlp/)（选读）  

读完从计划 Task 1 起 Jaeger 容器即可。
