# iot-learn-lab

Java IoT 后端 **运维学习实验** 多模块工程：用真实可跑的微服务 + WSL Docker 中间件，覆盖可观测性、网关、韧性、发布，以及 Stage 2 的 minikube / Ingress / Prometheus 混合部署。

**环境：** Windows + IntelliJ IDEA + WSL2 Docker  
**节奏：** 每周约 10–15 小时  
**设计文档：** 仓库根目录 `docs/superpowers/`（spec / plan / guide）

---

## 学习主线

```text
L4  发布与变更   蓝绿 / 金丝雀 / 回滚 /（Stage 2）GitOps
L3  应用韧性     Sentinel 限流熔断降级隔离
L2  网关防护     APISIX 限流 / 路由 / 金丝雀
L1  可观测性     Prometheus + Grafana 指标告警
         ↓ 横向支撑
    Kafka 削峰 + Redis 缓存 + Nacos 注册配置
```

| 阶段 | 主题 | 状态 |
|------|------|------|
| **Phase 1** | 可观测性（设备上报 + Prom/Grafana） | ✅ |
| **Phase 2** | 网关防护（APISIX） | ✅ |
| **Phase 3** | 应用韧性（Sentinel / Feign） | ✅ |
| **Phase 4** | 发布策略（v1/v2 金丝雀） | ✅ |
| **Phase 5** | 综合演练（Kafka / Redis 三高） | ✅ |
| **Stage 2 W1–W4** | minikube 三服务 + Ingress + Prom + Helm Chart | ✅ K1–K4 |
| **Stage 2 W5** | Values 分层 / checksum / canary 切换 | 文档已备，待执行 |
| **Stage 2 W6+** | Argo CD / Rollouts → Jaeger → CI/CD | 待开始 |

> 命名：`Phase 2` = 网关周；`Stage 2` = K8s 进阶阶段。二者不要混称。

---

## 模块

| 模块 | 端口 | 职责 |
|------|------|------|
| `device-report-service` | 8765（v2 常用 8766） | 设备上报；Feign 调 dispatch；Sentinel；Redis；Kafka 异步入口 |
| `command-dispatch-service` | 8767 | 指令下发（熔断/降级下游） |
| `device-report-consumer` | 8768 | 消费 `device-report-events` → PostgreSQL |

技术栈：Java 21 / Spring Boot 3.3.5 / Maven 多模块。

---

## 两种运行方式

### A. Phase 1–5：IDEA + WSL Docker（默认学习路径）

中间件在 WSL Docker：PostgreSQL、Redis、Kafka、Nacos、Prometheus、Grafana、APISIX。  
应用在 Windows IDEA 启动；APISIX upstream 常指向 `192.168.16.1:8765`。

```bash
cd iot-learn-lab
mvn -B -pl device-report-service,command-dispatch-service,device-report-consumer -am package -DskipTests

# 或 IDEA 分别 Run 三个模块
mvn spring-boot:run -pl device-report-service
```

健康检查：`http://localhost:8765/actuator/health`

### B. Stage 2：应用进 minikube（混合中间件）

- **进集群：** 三个 Java 服务（本仓库 `infra/k8s/`）
- **仍留 WSL Docker：** 上述中间件（含 Prometheus）
- Pod → 中间件：优先 `host.minikube.internal`；Nacos 常用 `192.168.19.64:8848`
- k8s profile 下 Nacos discovery/config **关闭**（Feign 用 Service DNS）

详见：[`infra/k8s/README.md`](infra/k8s/README.md)。

```bash
# 构建镜像（在 iot-learn-lab 根目录）
docker build -f device-report-service/Dockerfile -t device-report-service:0.1.0-SNAPSHOT .
docker build -f command-dispatch-service/Dockerfile -t command-dispatch-service:0.1.0-SNAPSHOT .
docker build -f device-report-consumer/Dockerfile -t device-report-consumer:0.1.0-SNAPSHOT .

minikube image load device-report-service:0.1.0-SNAPSHOT
minikube image load command-dispatch-service:0.1.0-SNAPSHOT
minikube image load device-report-consumer:0.1.0-SNAPSHOT

kubectl apply -f infra/k8s/namespace.yaml
kubectl apply -f infra/k8s/device-report/
kubectl apply -f infra/k8s/command-dispatch/
kubectl apply -f infra/k8s/device-report-consumer/
```

---

## 网络口诀（Windows / WSL / Pod）

| 地址 | 方向 | 典型用途 |
|------|------|----------|
| `192.168.16.1` | WSL → Windows | APISIX → IDEA 应用 |
| `192.168.19.64` | Windows → WSL | 浏览器访问 Prometheus / Nacos；Kafka advertised |
| `host.minikube.internal` | Pod → WSL Docker | DB / Redis / Kafka bootstrap |
| `$(minikube ip)` 如 `192.168.49.2` | 宿主机 → 集群 | Ingress / NodePort（30765/30767） |

---

## 目录结构

```text
iot-learn-lab/
├── pom.xml
├── device-report-service/          # 含 Dockerfile、application-k8s.yml
├── command-dispatch-service/
├── device-report-consumer/
├── infra/
│   ├── k8s/                        # Stage 2 裸 manifest + README
│   ├── kafka/                      # advertised.listeners（Pod 可达）
│   ├── prometheus/                 # scrape（含 *-k8s NodePort jobs）
│   ├── grafana/ · apisix/ · nacos/ · postgres/ · sentinel/ ...
├── scripts/
│   ├── phase1/ … phase5/           # 压测与场景脚本
│   └── stage2/                     # env.sh · scenario-k1/k2/k3
└── docs/                           # 各 Phase / Stage 面试复盘与 runbook
```

仓库级学习文档（spec / 分周计划 / 前置指南）：

```text
docs/superpowers/
├── specs/
│   ├── 2026-07-02-ops-learning-plan-design.md      # Phase 1–5 总设计
│   └── 2026-07-13-stage2-k8s-gitops-design.md      # Stage 2 总设计
├── plans/                                            # 各周 Implementation Plan
└── guides/                                           # W1/W2/W3 前置知识
```

---

## 场景脚本（速查）

| 目录 | 示例 | 验证什么 |
|------|------|----------|
| `scripts/phase1` | `scenario-s2-device-burst.sh` | 上报突刺与指标 |
| `scripts/phase2` | `scenario-g1` … `g6` | APISIX 限流 / 超时 / 下游挂 |
| `scripts/phase3` | `scenario-r1` … `r6` | Feign / Sentinel / 雪崩 |
| `scripts/phase4` | `scenario-c1` … `c4` | 双版本与金丝雀回滚 |
| `scripts/phase5` | `scenario-e1` … `e6` | 同步/异步削峰、缓存三高 |
| `scripts/stage2` | `scenario-k1` … `k5` | K8s 基线 / 三服务 / Ingress+Prom / Helm / Values 切换 |

Stage 2 在 WSL 中：

```bash
source scripts/stage2/env.sh
./scripts/stage2/scenario-k1-k8s-baseline.sh
./scripts/stage2/scenario-k2-three-services.sh
./scripts/stage2/scenario-k3-ingress-baseline.sh   # 期望结尾 K3 PASS
./scripts/stage2/scenario-k4-helm-baseline.sh      # W4：Helm Release 基线
./scripts/stage2/scenario-k5-helm-values-switch.sh # W5：v2+canary 切换
```

**Prometheus 抓 K8s（W3）：** scrape 指向 `$(minikube ip):30765/30767` 后，需让容器够到 minikube 网：

```bash
docker network connect minikube prometheus-learn
```

---

## 常用 API（device-report）

| 场景 | Method / Path |
|------|---------------|
| 同步上报 | `POST /api/v1/devices/{id}/reports` |
| Feign 联动 | `POST /api/v1/devices/{id}/reports-with-dispatch` |
| 异步削峰 | `POST /api/v1/devices/{id}/reports-async` |
| 健康 / 指标 | `GET /actuator/health` · `/actuator/prometheus` |

Ingress（Stage 2 W3）：

```bash
curl -H "Host: device-report.iot-learn.local" \
  http://$(minikube ip)/actuator/health
```

---

## 文档索引

| 类型 | 路径 |
|------|------|
| Phase 1–5 设计 | `docs/superpowers/specs/2026-07-02-ops-learning-plan-design.md` |
| Stage 2 设计 | `docs/superpowers/specs/2026-07-13-stage2-k8s-gitops-design.md` |
| W1 计划 / 指南 | `plans/2026-07-13-stage2-w1-minikube-dockerfile.md` · `guides/2026-07-14-stage2-w1-k8s-primer.md` |
| W2 计划 / 指南 | `plans/2026-07-16-stage2-w2-three-services.md` · `guides/2026-07-16-stage2-w2-service-dns-kafka.md` |
| W3 计划 / 指南 | `plans/2026-07-16-stage2-w3-ingress-prometheus.md` · `guides/2026-07-16-stage2-w3-ingress-prometheus.md` |
| W4 计划 / 指南 | `plans/2026-07-17-stage2-w4-helm-chart.md` · `guides/2026-07-17-stage2-w4-helm-primer.md` |
| W5 计划 / 指南 | `plans/2026-07-19-stage2-w5-helm-values.md` · `guides/2026-07-19-stage2-w5-helm-values.md` |
| K8s 操作与踩坑 | [`infra/k8s/README.md`](infra/k8s/README.md) |
| 面试复盘 | [`docs/stage2-interview-notes.md`](docs/stage2-interview-notes.md) · `docs/phase*-interview-notes.md` |

---

## 构建

```bash
cd iot-learn-lab
mvn clean verify
# 或跳过测试快速打包
mvn -B package -DskipTests
```
