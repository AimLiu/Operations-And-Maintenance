# Stage 2：K8s / Helm / GitOps / 链路追踪 / CI/CD 学习计划

**日期：** 2026-07-13  
**作者：** 学习计划设计（brainstorming 产出）  
**状态：** 已审阅（混合中间件方案）  
**前置：** Phase 1–5（`iot-learn-lab`）已完成

## 背景与目标

### 学习者画像（延续 Phase 1–5）

- 角色：Java IoT 后端开发人员
- 开发环境：**Windows + IntelliJ IDEA + WSL2 Docker**
- 时间投入：**每周 10–15 小时**
- Stage 2 周期：**8–10 周**

### Stage 2 与 Phase 1–5 的关系

| 名称 | 含义 | 状态 |
|------|------|------|
| Phase 1–5 | 原 10 周运维主线（可观测性 → 网关 → 韧性 → 金丝雀 → 综合） | ✅ 已完成 |
| **Stage 2** | 原 spec「第 2 阶段展望」：K8s + Helm + GitOps + Tracing + CI/CD | 🆕 本 spec |

> **命名约定：** 下文 **Stage 2** 专指 K8s 进阶阶段；原学习计划中的「Phase 2 网关层防护」不变，引用时用 **Phase 2（网关）** 避免混淆。

### Stage 2 学习目标

1. 能在 WSL **minikube** 上部署 Java 微服务，理解 Pod / Deployment / Service / Ingress
2. 能用 **Helm Chart** 管理 `iot-learn-lab` 多服务配置（含 v1/v2 values）
3. 能用 **Argo CD** 做 GitOps 同步，用 **Argo Rollouts** 复现 Phase 4 金丝雀（对标 APISIX traffic-split）
4. 能接入 **Jaeger + OpenTelemetry**，在 UI 中看到跨服务 trace
5. 能搭建 **GitHub Actions → GHCR → Argo CD** 的 CI/CD 最小闭环

### 成功标准（Stage 2 Checklist）

- [ ] minikube 集群 `kubectl get pods -A` 核心组件健康
- [ ] 3 个 Java 模块均有 Dockerfile，镜像可 build 并推送到 GHCR
- [ ] `helm upgrade` 可部署/回滚 `device-report-service`
- [ ] Argo Rollouts 金丝雀 10% → 观察 v2 错误率 → abort/rollback
- [ ] Jaeger UI 有一条 `ingress → report → feign → dispatch` 完整 trace
- [ ] GitHub Actions workflow 绿，push 后集群镜像更新
- [ ] 输出 `iot-learn-lab/docs/stage2-interview-notes.md`（≥4 则新故事）

---

## 架构决策：混合中间件（已选定）

### 决策

**Java 应用进 minikube；中间件继续运行在现有 WSL Docker。**

不采用「全量进 K8s」（PostgreSQL / Redis / Kafka / Nacos / Prometheus 全部 Helm 进集群），以降低 WSL 内存压力，并与 Phase 1–5 脚本保持兼容。

### 混合架构图

```text
┌─────────────────────────────────────────────────────────────────┐
│  WSL minikube（Stage 2 新增）                                    │
│                                                                  │
│  ┌──────────────┐    ┌─────────────────────────────────────────┐ │
│  │ Ingress      │───→│ device-report-service (Rollout, W7+)    │ │
│  │ (nginx addon)│    │ command-dispatch-service                  │ │
│  └──────────────┘    │ device-report-consumer                    │ │
│                      └──────────────┬──────────────────────────┘ │
│  ┌──────────────┐    ┌──────────────┴──────────┐                 │
│  │ Argo CD      │    │ Jaeger (W8)             │                 │
│  │ Argo Rollouts│    └─────────────────────────┘                 │
│  └──────────────┘                                                 │
└──────────────────────────┬──────────────────────────────────────┘
                           │
              host.minikube.internal（Pod → WSL Docker，首选）
                           │
┌──────────────────────────▼──────────────────────────────────────┐
│  现有 WSL Docker（Phase 1–5 保留，不迁移）                        │
│  PostgreSQL :5432 · Redis :6379 · Kafka :9092                    │
│  Nacos :8848 · Prometheus · Grafana · APISIX :9080               │
└─────────────────────────────────────────────────────────────────┘
```

### 混合方案优缺点

| 优点 | 缺点 |
|------|------|
| WSL 内存占用可控（minikube 建议 8GB） | Pod 访问宿主机网络需额外配置 |
| Phase 2–5 压测脚本大部分可复用 | 面试需说明「中间件在集群外」 |
| 降低一次性迁移风险 | 与「全托管 K8s 生产」仍有差距 |
| 可渐进把中间件迁入集群（W11+ 选修） | 跨网络故障排查略复杂 |

### Pod 访问 WSL 中间件的网络约定

Stage 2 在 Phase 1–5 网络口诀上新增第三条：**Pod 找 WSL Docker 用 `host.minikube.internal`**。

| 变量 / 地址 | 默认值 | 方向 | 说明 |
|-------------|--------|------|------|
| `WSL_TO_WINDOWS_IP` | `192.168.16.1`（`ip route` 网关） | WSL → Windows | Phase 1–5：APISIX upstream 指 IDEA 应用 |
| `WSL_FROM_WINDOWS_IP` | `192.168.19.64` | Windows → WSL Docker | Phase 1–5：Windows 访问中间件 |
| `POD_MIDDLEWARE_HOST` | `host.minikube.internal` | **Pod → WSL Docker** | **ConfigMap 首选**；解析后可能为 `192.168.49.1` |
| `host.minikube.internal` | minikube 内置 | Pod → 宿主机 | docker driver 下 Pod 访问 WSL Docker 中间件 |
| `SPRING_DATASOURCE_URL` | 通过 ConfigMap 注入 | — | 覆盖 `application.yml` 硬编码 |
| `SPRING_DATA_REDIS_HOST` | 同上 | — | |
| `SPRING_KAFKA_BOOTSTRAP_SERVERS` | 同上 | — | 如 `host.minikube.internal:9092` |
| `SPRING_CLOUD_NACOS_DISCOVERY_SERVER_ADDR` | ConfigMap；推荐 `192.168.19.64:8848` | — | Nacos 2.x 还需服务端正确宣告，见下 |

> **勿混淆：** `192.168.16.1` 是 WSL 访问 Windows 的网关，**不能**作为 Pod 连 PostgreSQL 的 `DB_HOST`。DB/Redis 优先 `host.minikube.internal`；Nacos 建议可达 IP（如 `192.168.19.64`）。

**Nacos 混合部署注意（W1 踩坑）：**

- 宿主机 `8848/9848` 映射正常、`nc` 通，仍可能刷 `127.0.0.1:9848`——客户端跟随了服务端错误宣告。
- Docker：用 `JAVA_OPT: "-Dnacos.inetutils.ip-address=<可达IP>"`（不要用 `JAVA_OPT_EXT` 传 `-D`，会被拼到 `-jar` 后失效）。
- 应用：勿在默认 profile 强制 `optional:nacos` import；W1 可关 discovery/config。
- 细节见 `iot-learn-lab/infra/k8s/README.md`。

**优先级：** ConfigMap / 环境变量 > `application-k8s.yml` profile > 默认 `application.yml`。

### 网关策略（分阶段）

| 阶段 | 入口 | 说明 |
|------|------|------|
| W1–W3 | `kubectl port-forward` / minikube Ingress | 先验证 Pod 内服务 |
| W4–W7 | 保留 **APISIX** 在 Docker，upstream 指向 minikube NodePort / Ingress | 与 Phase 4 金丝雀对照 |
| W8+ | 可选：APISIX 上游改 K8s Service | 统一入口故事 |

---

## 与 Phase 1–5 能力映射

| Phase 1–5 已掌握 | Stage 2 升级 |
|------------------|-------------|
| IDEA 本地 `:8765` / `:8767` / `:8768` | Deployment + Service +（可选）Ingress |
| APISIX `traffic-split` 金丝雀 | Argo Rollouts `canary` steps + AnalysisTemplate |
| Nacos 注册与配置热更新 | K8s Service 发现 + ConfigMap；Nacos 保留作对比 |
| Prometheus 抓 `/actuator/prometheus` | 保留外部 Prometheus scrape（NodePort/target）；W11+ 选修 ServiceMonitor |
| Grafana 按 `version` 看 v2 错误率 | Rollouts Prometheus Analysis 自动 abort |
| Phase 5 Kafka 异步 + Redis 三高 | Consumer 容器化；trace 覆盖 Kafka span |
| Phase 4 C4 权重回滚 | `kubectl argo rollouts abort` / Git revert |

---

## 技术选型

| 领域 | 选型 | 理由 |
|------|------|------|
| 本地 K8s | **minikube**（`--driver=docker`） | 与现有 WSL Docker 一致；Ingress / tunnel 文档成熟 |
| 包管理 | **Helm 3** | 业界标准；values 分层对应 v1/v2 |
| GitOps | **Argo CD** | 与 GitHub 集成简单 |
| 金丝雀 | **Argo Rollouts**（非仅 Argo CD） | 原生 canary + 指标分析；对标 Phase 4 |
| 链路追踪 | **Jaeger + OpenTelemetry**（Micrometer Tracing） | Spring Boot 3 官方路线；Zipkin 不单独部署 |
| CI | **GitHub Actions** | 与仓库同平台 |
| 镜像仓库 | **GHCR**（`ghcr.io`） | 免费额度；与 Actions 集成 |
| CD 触发 | **Git 更新 image tag → Argo CD Sync**（入门）；选修 Image Updater | 先理解 GitOps 本质 |

---

## 8–10 周分周计划

### Block A：K8s 基础 + 容器化（W1–W3）

#### W1：minikube + Dockerfile + 首个服务上集群

| 类型 | 内容 |
|------|------|
| 理论 | Pod / Deployment / Service；容器健康检查 |
| 动手 | 安装 minikube；3 模块 Dockerfile；部署 `device-report-service` |
| 产出 | `infra/k8s/`、`application-k8s.yml`、W1 实施计划 |
| 面试 | liveness vs readiness；为什么容器里不能写死 `localhost` 连 DB |

**实施计划：** `docs/superpowers/plans/2026-07-13-stage2-w1-minikube-dockerfile.md`

#### W2：三服务全部上集群 + 服务间调用

| 类型 | 内容 |
|------|------|
| 动手 | 部署 `command-dispatch-service`、`device-report-consumer` |
| 网络 | Feign 通过 K8s Service DNS（`command-dispatch-service:8767`） |
| 验证 | 同步上报 + 异步 Kafka 路径在 Pod 内跑通 |
| 产出 | `scripts/stage2/scenario-k2-three-services.sh` |

**实施计划：** `docs/superpowers/plans/2026-07-16-stage2-w2-three-services.md`  
**前置指南：** `docs/superpowers/guides/2026-07-16-stage2-w2-service-dns-kafka.md`

#### W3：Ingress + 与外部 Prometheus 联通

| 类型 | 内容 |
|------|------|
| 动手 | `minikube addons enable ingress`；Ingress 规则 |
| 监控 | Prometheus 增加 K8s Pod target（NodePort 或 host 网络） |
| 对照 | 压测对比 IDEA 直连 vs K8s Ingress 延迟 |
| 产出 | `scripts/stage2/scenario-k3-ingress-baseline.sh` |

---

### Block B：Helm 打包（W4–W5）

#### W4：Chart 骨架

| 类型 | 内容 |
|------|------|
| 理论 | Chart / Release / Values / Templates |
| 动手 | `infra/helm/iot-learn-lab/`；子 chart 或单 chart 多 deployment |
| 实验 | `helm install` / `upgrade` / `rollback` |
| 产出 | `values.yaml`、`values-v1.yaml`、`values-v2.yaml` |

#### W5：多环境与配置外置

| 类型 | 内容 |
|------|------|
| 动手 | ConfigMap 注入 DB/Redis/Kafka/Nacos 地址 |
| 实验 | 一条命令切换 v2 镜像与 `canary-bug-enabled` |
| 面试 | Helm vs Kustomize；ConfigMap 热更新限制 |
| 产出 | `docs/stage2-helm-cheatsheet.md` |

---

### Block C：Argo CD + Rollouts（W6–W7）

#### W6：Argo CD GitOps

| 类型 | 内容 |
|------|------|
| 理论 | Git 为唯一真相源；Sync / Prune / Self-heal |
| 动手 | 安装 Argo CD；Application 指向 `infra/helm/` |
| 实验 | 改 Git values → Argo UI Sync → 集群变化 |
| 产出 | `infra/argocd/application-iot-learn-lab.yaml` |

#### W7：Argo Rollouts 金丝雀

| 类型 | 内容 |
|------|------|
| 理论 | Rollout 替代 Deployment；canary steps；AnalysisRun |
| 动手 | `kind: Rollout` + 10% → 50% → 100% |
| 实验 | 复现 Phase 4 C3：v2 bug → v2 5xx↑ → abort |
| 指标 | AnalysisTemplate：`version=v2` 错误率 > 5% |
| 产出 | `scripts/stage2/scenario-k4-rollouts-canary.sh` |

**Phase 4 vs Rollouts 对照：**

| 维度 | Phase 4（APISIX） | Stage 2（Rollouts） |
|------|-------------------|---------------------|
| 流量切分 | upstream weight 90/10 | Rollout canary weight |
| 观测 | Grafana `version` label | AnalysisTemplate + Prometheus |
| 回滚 | `bootstrap-canary-rollback.sh` | `kubectl argo rollouts abort` |
| 配置热修 | Nacos `@RefreshScope` | 仍可用；或 ConfigMap reload |

---

### Block D：分布式链路追踪（W8）

| 类型 | 内容 |
|------|------|
| 理论 | Trace / Span / 三支柱（Metrics / Logs / Traces） |
| 动手 | `micrometer-tracing-bridge-otel` + OTLP exporter |
| 部署 | Jaeger all-in-one（Helm 或 manifest） |
| 实验 | `POST /reports` 全链路；Feign + Kafka consumer span |
| 产出 | `docs/stage2-tracing-runbook.md` |

---

### Block E：CI/CD（W9–W10）

#### W9：GitHub Actions 构建推送

| 类型 | 内容 |
|------|------|
| 动手 | `.github/workflows/iot-learn-lab-ci.yml` |
| 流程 | `mvn verify` → docker build → push GHCR |
| Tag | `${{ github.sha }}` 短 hash |

#### W10：CD 与 GitOps 闭环

| 类型 | 内容 |
|------|------|
| 动手 | CI 成功后更新 `values.yaml` 的 `image.tag` |
| 实验 | 改 Java 代码 → push → 集群 RollingUpdate |
| 产出 | `docs/stage2-cicd-runbook.md` |

**端到端链路：**

```text
git push → GitHub Actions (test + build + push GHCR)
              ↓
         更新 infra/helm/values.yaml image.tag
              ↓
         Argo CD 检测 diff → Sync → Rollout
              ↓
         Grafana / Jaeger 验证
```

---

### Block F：综合演练（W10 或 W11，选修 W11–12）

| 场景 | 内容 |
|------|------|
| **K5 终极演练** | CI 部署 v2 → Rollouts 金丝雀 → 指标 abort → Jaeger 定位 |
| **选修** | kube-prometheus-stack；中间件迁入集群 |
| **文档** | `stage2-interview-notes.md` 定稿 |

---

## 文件结构规划（Stage 2 全周期）

```text
iot-learn-lab/
├── device-report-service/
│   ├── Dockerfile
│   ├── .dockerignore
│   └── src/main/resources/
│       └── application-k8s.yml          # W1：K8s 环境变量默认值
├── command-dispatch-service/
│   ├── Dockerfile
│   └── .dockerignore
├── device-report-consumer/
│   ├── Dockerfile
│   └── .dockerignore
├── infra/
│   ├── k8s/                             # W1–W3 裸 manifest
│   │   ├── README.md
│   │   ├── namespace.yaml
│   │   ├── device-report/
│   │   ├── command-dispatch/
│   │   └── device-report-consumer/
│   ├── helm/iot-learn-lab/              # W4+
│   ├── argocd/                          # W6+
│   └── jaeger/                          # W8+
├── scripts/stage2/
│   ├── scenario-k1-k8s-baseline.sh
│   ├── scenario-k2-three-services.sh
│   ├── scenario-k3-ingress-baseline.sh
│   └── scenario-k4-rollouts-canary.sh
└── docs/
    ├── stage2-interview-notes.md
    ├── stage2-helm-cheatsheet.md
    ├── stage2-tracing-runbook.md
    └── stage2-cicd-runbook.md

.github/workflows/
└── iot-learn-lab-ci.yml                 # W9

docs/superpowers/
├── specs/2026-07-13-stage2-k8s-gitops-design.md   # 本文件
├── plans/2026-07-13-stage2-w1-minikube-dockerfile.md
├── plans/2026-07-16-stage2-w2-three-services.md
├── guides/2026-07-14-stage2-w1-k8s-primer.md
└── guides/2026-07-16-stage2-w2-service-dns-kafka.md
```

---

## 环境要求

| 项 | 最低 | 推荐 |
|----|------|------|
| WSL 内存 | 8 GB（minikube 分配 4–6 GB） | 16 GB |
| WSL 磁盘 | 30 GB 可用 | 50 GB |
| CPU | 4 核 | 6+ 核 |
| 软件 | Docker（WSL）、kubectl、minikube、helm（W4+） | 同上 |
| 网络 | ConfigMap 用 `host.minikube.internal`；部署前 `minikube ssh -- nc -zv host.minikube.internal 5432` | 固定 `.wslconfig` memory |

**minikube 启动参考：**

```bash
minikube start \
  --driver=docker \
  --cpus=4 \
  --memory=6144 \
  --kubernetes-version=stable
minikube addons enable ingress
minikube addons enable metrics-server
```

---

## 学习依赖顺序

```text
W1 minikube + Dockerfile + 单服务部署
  ↓
W2 三服务 + Feign/Kafka
  ↓
W3 Ingress + Prometheus target
  ↓
W4–W5 Helm
  ↓
W6 Argo CD
  ↓
W7 Argo Rollouts（依赖监控指标）
  ↓
W8 Jaeger（依赖集群内调用链）
  ↓
W9–W10 CI/CD（依赖 Dockerfile + Helm values）
  ↓
综合演练
```

**禁止并行：** 未手动 `helm upgrade` 跑通金丝雀前，不接 CI/CD 自动部署。

---

## 面试故事扩展（Stage 2 新增）

1. **混合部署取舍** — 为什么应用进 K8s、中间件留 Docker；生产如何演进  
2. **APISIX 金丝雀 vs Argo Rollouts** — 入口流量 vs 应用发布控制器  
3. **Jaeger 排障** — trace 树、慢 span、跨服务 trace_id 传播  
4. **GitOps 闭环** — commit → CI → 镜像 → manifest → Argo Sync → 可观测性验证  

---

## 推荐学习资源

| 主题 | 资源 |
|------|------|
| minikube | https://minikube.sigs.k8s.io/docs/start/ |
| Helm | https://helm.sh/docs/intro/quickstart/ |
| Argo CD | https://argo-cd.readthedocs.io/en/stable/getting_started/ |
| Argo Rollouts | https://argo-rollouts.readthedocs.io/en/stable/getting-started/ |
| Spring Boot 3 Tracing | https://docs.spring.io/spring-boot/docs/current/reference/html/actuator.html#actuator.micrometer-tracing |
| Jaeger | https://www.jaegertracing.io/docs/ |
| GitHub Actions + GHCR | https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry |

---

## 与原 Spec 的衔接

本 Stage 2 spec 实现原 `2026-07-02-ops-learning-plan-design.md` 末尾「第 2 阶段展望」四项：

1. ✅ WSL minikube + 服务迁移（混合中间件）  
2. ✅ Helm + Argo CD + Rollouts 金丝雀  
3. ✅ Jaeger（OTel）链路追踪  
4. ✅ GitHub Actions CI/CD  

原 spec 成功标准在 Stage 2 完成后扩展为 Stage 2 Checklist（见上文）。

---

## 变更记录

| 日期 | 变更 |
|------|------|
| 2026-07-13 | 初版；中间件方案定为 **混合** |
| 2026-07-16 | 补充 W2 实施计划与 Service DNS / Kafka 前置指南链接 |
