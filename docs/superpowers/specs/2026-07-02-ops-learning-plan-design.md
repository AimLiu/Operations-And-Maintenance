# Java IoT 后端运维知识学习计划

**日期：** 2026-07-02  
**作者：** 学习计划设计（brainstorming 产出）  
**状态：** 待审阅

## 背景与目标

### 学习者画像

- 角色：Java IoT 后端开发人员
- 开发环境：Windows + IntelliJ IDEA + WSL Docker
- 学习动机：**A（提升日常开发能力）为主**，兼顾面试准备
- 时间投入：**每周 10–15 小时**

### 学习目标

1. 能配置和验证限流、熔断、降级（而不只是背概念）
2. 能看懂 Prometheus/Grafana 指标，参与发布与故障讨论
3. 能解释蓝绿/金丝雀/滚动发布的取舍，以及和防雪崩的关系
4. 面试时能讲述完整的「我做过什么、为什么这么设计」故事

### 核心问题：版本发布 vs 防雪崩是否相关？

相关，但属于不同层面，在故障场景里会叠加：


| 维度   | 版本发布（Release/Deploy） | 高并发稳定性 / 防雪崩（Resilience） |
| ---- | -------------------- | ------------------------ |
| 核心问题 | 如何**安全地变更**系统        | 系统**在压力下如何存活**           |
| 典型手段 | 蓝绿/金丝雀/滚动发布、回滚、CI/CD | 限流、熔断、降级、隔离、缓存、异步削峰      |
| 时间特征 | 发布窗口内的风险             | 日常运行 + 流量突增 + 故障扩散       |


**交叉点：** 糟糕发布可触发连锁故障；金丝雀发布 + 自动回滚本质也是防雪崩；限流/熔断保护「运行时」，发布策略保护「变更时」。

---



## 学习架构

四层模型，从上到下依次攻克：

```
┌─────────────────────────────────────────────┐
│  L4 发布与变更  蓝绿 / 金丝雀 / 回滚 / CI     │
├─────────────────────────────────────────────┤
│  L3 应用韧性    Sentinel 限流熔断降级隔离      │
├─────────────────────────────────────────────┤
│  L2 网关防护    APISIX 限流 / 路由 / 金丝雀    │
├─────────────────────────────────────────────┤
│  L1 可观测性    Prometheus + Grafana 指标告警  │
└─────────────────────────────────────────────┘
         ↓ 横向支撑
    Kafka 削峰  +  Redis 缓存  +  Nacos 注册配置
```



### 学习原则

- 每层：理解原理 → 本地实验 → 模拟故障 → 看监控变化
- 每周：3h 理论 + 7–9h 动手 + 2–3h 复盘/面试题整理
- 贯穿项目：IoT 设备上报 + 指令下发微服务实验



### 现有 Docker 组件复用


| 组件                   | 学习用途                            |
| -------------------- | ------------------------------- |
| APISIX + etcd        | 入口限流、金丝雀路由、熔断（需修复 unhealthy 状态） |
| Nacos                | 服务注册、配置中心、灰度元数据                 |
| Prometheus + Grafana | QPS/延迟/错误率监控、告警规则               |
| Redis                | 缓存降级、分布式限流计数                    |
| Kafka                | 异步削峰、设备上报缓冲                     |
| PostgreSQL           | 业务数据存储、慢查询故障模拟、连接池耗尽实验          |
| Keycloak             | 暂不纳入主线                          |




### 需新增（轻量）

- 1–2 个 Spring Boot 微服务
- Sentinel（Maven 依赖，可选 sentinel-dashboard 容器）
- docker-compose 编排实验服务



### 技术栈约定


| 层次    | 技术选型                             |
| ----- | -------------------------------- |
| 语言/框架 | Java 21 / Spring Boot 3.x / Maven 多模块 |
| 服务端口 | device-report-service 默认 **8765**（金丝雀 v2 可用 **8766**） |
| 数据库   | PostgreSQL 16（`postgres-alpine`） |
| ORM   | Spring Data JPA 或 MyBatis-Plus   |
| 缓存    | Redis 7                          |
| 消息队列  | Kafka 3.9                        |
| 注册/配置 | Nacos 2.5                        |
| 网关    | APISIX 3.13                      |
| 监控    | Prometheus + Grafana             |
| 韧性    | Sentinel + Nacos 规则持久化           |


**PostgreSQL 连接（实验用）：**

```
Host: localhost（WSL 内服务用 postgres-alpine 或 host.docker.internal）
Port: 5432
Database: iot_learn（需自行创建）
```

---



## 学习路径方案对比



### 方案 A：以现有 Docker 栈为核心（本计划采用）

复用 APISIX + Nacos + Prometheus/Grafana + Kafka + Redis + PostgreSQL + 自建 Spring Boot 服务。


| 优点                 | 缺点                |
| ------------------ | ----------------- |
| 零额外成本，组件已在运行       | 不涉及 K8s 编排层       |
| IoT 网关 + 注册中心贴近实战  | 多容器手工编排，发布流程需自己模拟 |
| Java 后端可直接写业务代码做实验 | 与「真实生产 K8s 发布」有差距 |




### 方案 B：K8s 迷你集群（第 2 阶段进阶）

在 WSL 中加 kind 或 minikube。


| 优点              | 缺点                      |
| --------------- | ----------------------- |
| 业界事实标准，简历加分     | WSL 资源占用大，学习曲线陡         |
| 原生支持滚动/金丝雀/HPA  | 与 APISIX 有部分功能重叠        |
| 与云厂商托管 K8s 概念一致 | 本地调试比 Docker Compose 麻烦 |




### 方案 C：纯 Java 应用层韧性（Sentinel 专项）


| 优点                | 缺点              |
| ----------------- | --------------- |
| 和 Java IoT 开发直接相关 | 视野偏窄，缺网关/基础设施层  |
| 阿里系文档中文丰富         | 发布流程、基础设施运维覆盖不足 |
| 可快速看到限流/熔断效果      | 难以练完整发布流水线      |




### 推荐策略

**方案 A 为主 + 方案 C 为辅，10 周完成后再补方案 B。**

---



## 10 周分阶段学习计划



### Phase 1：可观测性基础（第 1–2 周）

**目标：** 能看懂监控大盘，知道系统出问题时先看什么指标。


| 周   | 理论学习                      | 动手实验                                                                                          | 面试考点                     |
| --- | ------------------------- | --------------------------------------------------------------------------------------------- | ------------------------ |
| W1  | 可观测性三板斧；黄金信号：延迟、流量、错误、饱和度 | Spring Boot 接入 micrometer + prometheus；Grafana 建 Dashboard（QPS、P99、JVM、错误率）；PostgreSQL 存储设备上报 | 「怎么监控服务健康？」「P99 和平均值区别？」 |
| W2  | 告警设计原则；SLI/SLO/SLA；RED 方法 | Prometheus 配告警（错误率 > 5%、P99 > 500ms）；Grafana 告警通知；修复 APISIX unhealthy                         | 「告警太多怎么办？」「什么是 SLI？」     |


**W1 产出：** `device-report-service`（Spring Boot + PostgreSQL），`/actuator/prometheus` 可采集。  
**W2 产出：** 告警验证通过；APISIX 健康检查正常；Dashboard 含 HikariCP 连接池指标。

---



### Phase 2：网关层防护（第 3–4 周）

**目标：** 能在 APISIX 配置限流和路由策略。


| 周   | 理论学习              | 动手实验                                                 | 面试考点                    |
| --- | ----------------- | ---------------------------------------------------- | ----------------------- |
| W3  | 限流算法（令牌桶/漏桶/滑动窗口） | APISIX `limit-req` / `limit-count`；ab/wrk 压测观察 429   | 「令牌桶和漏桶区别？」「限流放网关还是应用？」 |
| W4  | 熔断原理；超时配置重要性      | APISIX 上游超时；模拟下游宕机；PostgreSQL 慢查询（`pg_sleep`）观察连接池打满 | 「熔断和降级区别？」「为什么要有超时？」    |


**实验架构：**

```
压测工具 → APISIX(:9080) → device-report-service → PostgreSQL / Redis
                ↓ 限流插件
           Prometheus 采集 APISIX + 应用指标
```

**W4 慢查询示例：**

```sql
SELECT * FROM device_report
WHERE device_id = $1 AND pg_sleep(3) IS NOT NULL;
```

---



### Phase 3：应用层韧性（第 5–6 周）

**目标：** 能在 Java 代码里配 Sentinel，理解第二道防线。


| 周   | 理论学习                   | 动手实验                                                           | 面试考点                                     |
| --- | ---------------------- | -------------------------------------------------------------- | ---------------------------------------- |
| W5  | 雪崩效应完整链路；Sentinel 核心概念 | Sentinel + Nacos 持久化；QPS 限流 + fallback                         | 「什么是雪崩？」「雪崩怎么一步步发生？」                     |
| W6  | 熔断降级、线程隔离              | 新增 `command-dispatch-service`；Feign 调用 + 熔断；Redis 降级；关下游对比有无熔断 | 「Hystrix 和 Sentinel 区别？」「线程隔离和信号量隔离怎么选？」 |


**实验架构：**

```
APISIX → device-report-service ──Feign──→ command-dispatch-service
              ↓ Sentinel 限流                    ↓ Sentinel 熔断
           Redis 缓存                         Kafka 异步下发
                                                ↓
                                           PostgreSQL
```

**W6 雪崩模拟（面试核心故事）：**

1. 关掉 `command-dispatch-service`
2. 无熔断：观察 device-report 线程池打满、响应变慢
3. 有熔断：快速失败 + 降级，上游存活

---



### Phase 4：发布策略（第 7–8 周）

**目标：** 理解三种发布方式，本地模拟金丝雀发布。


| 周   | 理论学习             | 动手实验                                                  | 面试考点                   |
| --- | ---------------- | ----------------------------------------------------- | ---------------------- |
| W7  | 滚动/蓝绿/金丝雀对比；功能开关 | 两版本 device-report（v1/v2）；Nacos 注册；APISIX 权重 90/10     | 「三种发布优缺点？」「什么场景用金丝雀？」  |
| W8  | 发布可观测性；自动回滚条件    | 部署有 bug 的 v2；Grafana 观察错误率；权重回滚 100% v1；写发布 Checklist | 「发布失败怎么发现？」「自动回滚触发条件？」 |


**金丝雀路由：**

```
APISIX:
  device-report-v1  weight=90  →  :8765
  device-report-v2  weight=10  →  :8766
Grafana 对比 v1 vs v2 错误率、延迟
```

---



### Phase 5：综合演练 + 面试冲刺（第 9–10 周）

**目标：** 串联全流程，能流畅讲述完整方案。


| 周   | 理论学习                | 动手实验                                           | 面试考点                        |
| --- | ------------------- | ---------------------------------------------- | --------------------------- |
| W9  | Kafka 削峰；缓存穿透/击穿/雪崩 | 上报写 Kafka → 消费者批量入 PostgreSQL；10x 压测对比同步 vs 异步 | 「IoT 高并发怎么设计？」「Kafka 怎么削峰？」 |
| W10 | 综合复盘；K8s 概念预习       | 终极演练：流量突增 + 下游故障 + 金丝雀 bug；限流→熔断→降级→回滚         | 「设计一个高可用 IoT 平台」            |


**W9 架构：**

```
设备上报 → APISIX → device-report-service
                        ├─ 同步 → PostgreSQL（易打满连接池）
                        └─ 异步 → Kafka → Consumer 批量 INSERT → PostgreSQL
```

**W10 面试故事集：**

1. 雪崩发生与防护（W6）
2. 金丝雀发布与回滚（W7–W8）
3. 监控告警配置（W1–W2）
4. IoT 高并发整体架构（W9 + 全局）

---



### 时间线

```
W1-2   ████████ 可观测性（地基）
W3-4   ████████ 网关防护（L2）
W5-6   ████████ 应用韧性（L3）← 面试重点
W7-8   ████████ 发布策略（L4）
W9-10  ████████ 综合 + 面试冲刺
```

---



## 推荐学习资源



### 官方文档（优先）


| 主题                   | 资源                                                                                                                                                           |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| APISIX 限流/熔断         | [https://apisix.apache.org/docs/apisix/plugins/limit-count/](https://apisix.apache.org/docs/apisix/plugins/limit-count/)                                     |
| Sentinel             | [https://sentinelguard.io/zh-cn/docs/introduction.html](https://sentinelguard.io/zh-cn/docs/introduction.html)                                               |
| Prometheus           | [https://prometheus.io/docs/prometheus/latest/querying/basics/](https://prometheus.io/docs/prometheus/latest/querying/basics/)                               |
| Grafana 告警           | [https://grafana.com/docs/grafana/latest/alerting/](https://grafana.com/docs/grafana/latest/alerting/)                                                       |
| Nacos                | [https://nacos.io/docs/latest/what-is-nacos/](https://nacos.io/docs/latest/what-is-nacos/)                                                                   |
| Spring Boot Actuator | [https://docs.spring.io/spring-boot/docs/current/reference/html/actuator.html](https://docs.spring.io/spring-boot/docs/current/reference/html/actuator.html) |




### 书籍


| 书名                          | 适合阶段       | 说明                      |
| --------------------------- | ---------- | ----------------------- |
| 《Release It!》Michael Nygard | W5–W6      | 雪崩、稳定性模式经典，面试常引用        |
| 《SRE：Google 运维解密》           | W1–W2, W10 | SLI/SLO、可观测性理论基础        |
| 《凤凰架构》周志明（在线免费）             | 全程         | 中文，涵盖熔断限流发布，与 Java 生态贴合 |




### 视频/专栏

- 阿里云 Sentinel 官方教程（B站/阿里云大学）
- APISIX 官方 Workshop



### 压测工具

- `wrk` / `ab`：HTTP 压测
- Grafana k6（可选）：脚本化压测

---



## 业界方案速查（面试用）



### 版本发布


| 方案     | 典型用户         | 特点                    |
| ------ | ------------ | --------------------- |
| 滚动发布   | K8s 默认       | 简单，新旧共存窗口             |
| 蓝绿发布   | AWS、金融       | 回滚快，资源双倍              |
| 金丝雀发布  | Google、阿里    | 风险最小，需流量调度            |
| GitOps | Cloud Native | Git 为真相源，Argo CD/Flux |




### 防雪崩


| 手段  | 代表                    | 层级      |
| --- | --------------------- | ------- |
| 限流  | APISIX、Sentinel       | 网关 / 应用 |
| 熔断  | Resilience4j、Sentinel | 应用      |
| 降级  | Sentinel fallback     | 应用      |
| 隔离  | 线程池/信号量               | 应用      |
| 削峰  | Kafka                 | 架构      |
| 缓存  | Redis                 | 架构      |
| 扩缩容 | K8s HPA               | 基础设施    |


---



## 第 2 阶段展望（10 周后）

若需继续深入或强化面试：

1. WSL 部署 kind/minikube，将实验服务迁移到 K8s
2. 学习 Helm 打包、Argo CD 金丝雀（Rollouts）
3. 接入 Jaeger/Zipkin 补全链路追踪
4. CI/CD：GitHub Actions 构建镜像 + 推送 + 触发部署

---



## 成功标准

- [ ] Grafana 有完整 IoT 实验服务 Dashboard
- [x] 能演示限流（APISIX）和熔断（Sentinel）效果
- [ ] 完成雪崩模拟对比实验（有/无熔断）
- [ ] 完成金丝雀发布与手动回滚
- [ ] 整理 4 则面试故事（含截图/指标）
- [ ] 输出《发布 Checklist》模板