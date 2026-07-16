# Stage 2 W1：minikube + Dockerfile + 首个服务上集群 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 WSL 启动 **minikube**（混合中间件模式），为 `iot-learn-lab` 三个 Java 模块编写 **Dockerfile**，将 **`device-report-service`** 首次部署到集群并通过健康检查，Pod 能访问 WSL Docker 中的 PostgreSQL / Redis / Nacos。

**Architecture:** Java 服务运行在 minikube Pod 内；PostgreSQL、Redis、Kafka、Nacos、Prometheus、APISIX **仍在现有 WSL Docker**。Pod 访问中间件优先用 **`host.minikube.internal`**（docker driver 下解析为 minikube 宿主机，如实测 `192.168.49.1`）；**不要**用 `192.168.16.1`（那是 WSL→Windows 网关）。通过 `application-k8s.yml` + ConfigMap 注入连接地址。W1 仅部署 `device-report-service`；W2 再部署其余两服务。

**Tech Stack:** Java 21, Spring Boot 3.3.5, minikube (docker driver), kubectl, Docker 24+, 现有 WSL 中间件栈

**Spec 来源:** `docs/superpowers/specs/2026-07-13-stage2-k8s-gitops-design.md`（混合中间件方案）

**前置条件（Phase 1–5 已完成）:**

- [x] WSL Docker 中 PostgreSQL / Redis / Nacos 可访问（WSL 内 `localhost:5432` 等；Windows 侧用 `192.168.19.64`）
- [x] `device-report-service` 在 Windows IDEA `:8765` 可正常启动
- [x] `mvn -f iot-learn-lab/pom.xml clean verify` 通过
- [x] WSL 已安装 Docker，且 `docker ps` 正常
- [x] 本机可运行 `minikube` / `kubectl`（Task 1：集群 Ready，kubeconfig Configured）

**时间预算:** 1 周 × 10–15h

**W1 边界:**

| W1 做 | W1 不做 |
|-------|---------|
| minikube 安装与验证 | Helm Chart（W4） |
| 3 个 Dockerfile（先 build 一个） | Argo CD / Rollouts（W6–W7） |
| `device-report-service` Deployment + Service | Ingress 完整路由（W3） |
| `application-k8s.yml` + ConfigMap | Jaeger / CI/CD（W8–W10） |
| `infra/k8s/README.md` | 中间件迁入 K8s |

---

## 前置知识：kubectl、minikube 与镜像的关系

> 执行 Task 1 前先读完本节。目标：分清「谁建集群、谁管集群、谁在集群里跑」。

### 一句话关系

| 组件 | 角色 |
|------|------|
| **minikube** | 在 WSL Docker 里**搭 / 启停**本地 Kubernetes 集群的工具 |
| **kubectl** | 对**已存在的** K8s 集群发指令的客户端（查节点、部署 Pod、改配置） |
| **镜像（images）** | 集群节点与控制面真正运行的**容器程序**；W1 后期还有你自己的 Java 业务镜像 |

```text
你 (WSL 终端)
  │
  ├─ minikube   → 创建 / 启动 / 停止本地 K8s；写入 kubeconfig
  │
  └─ kubectl    → 读取 kubeconfig，向 API Server 发请求
                      │
                      ▼
              minikube 用 Docker 创建的节点容器
                      │
                      └─ 内含系统镜像（kicbase、apiserver、kubelet…）
                         之后再挂载你 build 的业务镜像（device-report-service 等）
```

### minikube 做什么

- 用 `--driver=docker` 在现有 WSL Docker 中创建一个名为 `minikube` 的节点容器
- 在节点内启动完整 Kubernetes（控制面 + kubelet）
- 生成 `~/.kube/config`，让 `kubectl` 知道连哪里（一般是 `https://127.0.0.1:xxxx`，**不是**默认的 `8080`）
- 管理 addons（如 `metrics-server`、`storage-provisioner`、后续的 `ingress`）

常用命令：`minikube start` / `status` / `stop` / `delete` / `addons enable …` / `image load …`

### kubectl 做什么

- **不创建集群**；集群不存在或 kubeconfig 未配置时，会退回默认地址 `http://localhost:8080`
- 集群就绪后：`kubectl get nodes`、`kubectl apply -f …`、`kubectl logs`、`kubectl port-forward`

验证集群就绪：

```bash
minikube status
# 预期：host / kubelet / apiserver 均为 Running；kubeconfig: Configured

kubectl get nodes
# 预期：NAME=minikube，STATUS=Ready
```

### 镜像分两类（别混）

**A. minikube 自带的系统镜像（`minikube start` 时拉取）**

| 镜像 | 作用 |
|------|------|
| `gcr.io/k8s-minikube/kicbase:…` | 节点「壳子」：整个 minikube 控制面节点跑在这个容器里 |
| Kubernetes 控制面 / 节点组件 | apiserver、controller-manager、scheduler、etcd、kubelet、CNI 等 |
| `storage-provisioner` 等 addon | 本地动态存储等能力（start 日志里会显示 Enabled addons） |

**B. 你项目在 W1 构建的业务镜像（Task 4 之后）**

| 镜像 | 作用 |
|------|------|
| `device-report-service:0.1.0-SNAPSHOT` | Spring Boot 应用，进 Pod |
| 其余两模块镜像 | W1 先 build；W2 再部署 |

流程：`docker build` → `minikube image load` → `kubectl apply`（Deployment 引用该镜像）→ Pod 运行。

### 与本仓库混合架构的对应

```text
┌─ WSL Docker ──────────────────────────────────────────────────┐
│                                                               │
│  ┌─ minikube 节点容器（kicbase + K8s 系统组件）─────────────┐ │
│  │  kubectl 操作的对象在这里                                  │ │
│  │  W1 起跑：device-report-service Pod（业务镜像）           │ │
│  └───────────────────────────────────────────────────────────┘ │
│                                                               │
│  Phase 1–5 中间件（不迁入 K8s）                                │
│  postgres / redis / nacos / kafka / prometheus / apisix …    │
└───────────────────────────────────────────────────────────────┘
```

| 层 | 谁管 | 用什么命令 |
|----|------|------------|
| 本地集群生命周期 | minikube | `minikube start/stop/status` |
| 集群内资源（Pod/Service） | kubectl | `kubectl get/apply/logs` |
| 宿主机中间件容器 | Docker | `docker ps` / Compose |
| 把本地业务镜像给集群用 | minikube | `minikube image load <image>` |

### 安装踩坑速查（来自实操）

| 现象 | 原因 | 处理 |
|------|------|------|
| `kubectl` 报 `localhost:8080 connection refused`，`lsof -i :8080` 为空 | **不是端口冲突**；集群未起来或没有 `~/.kube/config`，kubectl 退回默认 8080 | 先 `minikube start` 成功；再 `minikube status` / `kubectl get nodes` |
| `minikube cannot pull kicbase` / 提及 proxy 与 HTTP | Docker Hub / gcr 或代理不通，**节点基础镜像拉不下来** | 修好网络/镜像加速/代理；或手动 `docker pull`/`docker load` kicbase 后再 `minikube start` |
| 启动日志有 `Docker machine "minikube" does not exist`，随后又 `Done!` | 上次失败留下的空 profile，本次重新创建 | 只要最后出现 `Done! kubectl is now configured…` 且 `kubectl get nodes` Ready，即可忽略 |
| 成功标志 | — | `minikube status` 四项 Running/Configured；`kubectl get nodes` 为 Ready |

### W1 部署时序（心智模型）

1. `minikube start` → 系统镜像就绪，kubeconfig 已写  
2. `docker build` → 业务镜像在宿主机 Docker  
3. `minikube image load` → 镜像进入 minikube 节点  
4. `kubectl apply` → 创建 Deployment/Service，调度 Pod  
5. Pod 经 **`host.minikube.internal`**（ConfigMap `POD_MIDDLEWARE_HOST`）访问 WSL 中间件  

---

## WSL 混合网络拓扑（W1）

### Stage 2 网络 IP 方向（在 Phase 1–5 口诀上扩展）

Phase 1–5 口诀：**Java 找 Docker 用 `192.168.19.64`；Docker 找 Java 用 `192.168.16.1`**。  
Stage 2 新增第三条：**Pod 找 WSL Docker 用 `host.minikube.internal`**。

| IP / 主机名 | 方向 | 典型用途 | Stage 2 ConfigMap？ |
|-------------|------|----------|---------------------|
| `192.168.16.1` | WSL → **Windows** | APISIX upstream 指 Windows IDEA `:8765` | ❌ 不要填给 Pod |
| `192.168.19.64` | **Windows** → WSL Docker | Windows 浏览器访问 Grafana / Postgres | ❌ 备选；Pod 优先不用 |
| `host.minikube.internal` | **Pod** → WSL Docker | minikube docker driver 访问宿主机中间件 | ✅ **首选** |
| `192.168.49.1`（示例） | 同上，解析结果 | `host.minikube.internal` 在你环境可能解析为此 IP | 仅排障对照，不必硬编码 |
| `localhost` | WSL 终端 → WSL Docker | WSL 内自检中间件是否启动 | WSL 自检用，不给 Pod |

> **常见误区：** `ip route default gateway`（`192.168.16.1`）是 WSL 访问 **Windows** 的网关，**不是** Pod 访问 WSL Docker 的地址。旧变量名 `WSL_HOST_IP` 易误导，已改为 `POD_MIDDLEWARE_HOST`。

```text
Windows (IDEA :8765)
    ↑ 192.168.16.1  (WSL → Windows)
    │
WSL Docker (postgres / redis / nacos / kafka …)
    ↑ 192.168.19.64 (Windows → WSL，Phase 1–5)
    │
Windows 浏览器 / IDEA

WSL Docker 中间件
    ↑ host.minikube.internal  (→ 192.168.49.1 等，Pod → WSL Docker)
    │
minikube Pod (device-report-service)
```

```text
┌─ minikube (docker driver) ─────────────────────────────────────┐
│  Pod: device-report-service                                       │
│    DB_HOST / REDIS_HOST / NACOS_ADDR → host.minikube.internal     │
└────────────────────────────┬─────────────────────────────────────┘
                             │ host.minikube.internal (实测或解析为 192.168.49.1)
┌────────────────────────────▼─────────────────────────────────────┐
│  WSL Docker（不变）                                                │
│  postgres :5432 · redis :6379 · nacos :8848 · kafka :9092       │
└──────────────────────────────────────────────────────────────────┘
```

**环境变量（`scripts/stage2/env.sh`）：**

```bash
# WSL → Windows（Phase 1–5 沿用）
export WSL_TO_WINDOWS_IP="${WSL_TO_WINDOWS_IP:-$(ip -4 route show default | awk '{print $3}')}"

# Windows → WSL Docker
export WSL_FROM_WINDOWS_IP="${WSL_FROM_WINDOWS_IP:-192.168.19.64}"

# Pod → WSL Docker（ConfigMap 注入用）
export POD_MIDDLEWARE_HOST="${POD_MIDDLEWARE_HOST:-host.minikube.internal}"

export IMAGE_DEVICE_REPORT="device-report-service:0.1.0-SNAPSHOT"
export K8S_NAMESPACE="iot-learn"
```

### 连通性验证（两层）

**层 1 — WSL 终端：中间件是否在跑**

```bash
nc -zv localhost 5432
nc -zv localhost 6379
nc -zv localhost 8848
```

**层 2 — minikube 节点：Pod 视角能否连上（部署前必做）**

```bash
minikube ssh -- nc -zv host.minikube.internal 5432
minikube ssh -- nc -zv host.minikube.internal 6379
minikube ssh -- nc -zv host.minikube.internal 8848
```

Expected: 均为 `succeeded`。若 `host.minikube.internal` 不通，再试 `hostname -I` 得到的 WSL IP；**不要**用 `192.168.16.1`。

---

## 文件结构（W1 新增）

```text
iot-learn-lab/
├── device-report-service/
│   ├── Dockerfile
│   ├── .dockerignore
│   └── src/main/resources/
│       └── application-k8s.yml
├── command-dispatch-service/
│   ├── Dockerfile
│   └── .dockerignore
├── device-report-consumer/
│   ├── Dockerfile
│   └── .dockerignore
├── infra/k8s/
│   ├── README.md
│   ├── namespace.yaml
│   └── device-report/
│       ├── configmap-env.yaml
│       ├── deployment.yaml
│       └── service.yaml
└── scripts/stage2/
    ├── env.sh
    └── scenario-k1-k8s-baseline.sh
```

---

## 学习场景 K1：K8s 基线验证（W1 Day 5）

| 项 | 内容 |
|----|------|
| **操作** | `minikube image load` → `kubectl apply` → `kubectl port-forward` → `curl /actuator/health` |
| **预期** | `{"status":"UP"}`；`POST /api/v1/reports` 返回 201；PostgreSQL 有记录 |
| **面试** | 「混合部署时 Pod 怎么连宿主机上的 DB？」 |

---

### Task 1: 安装 minikube 与 kubectl（WSL）

> 先读上文 **「前置知识：kubectl、minikube 与镜像的关系」**，再执行本 Task。

**Files:**
- Create: `iot-learn-lab/infra/k8s/README.md`（前半：环境安装；可摘要前置知识中的角色表与踩坑速查）

- [ ] **Step 1: 安装 kubectl（WSL Ubuntu/Debian）**

```bash
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/
kubectl version --client
```

Expected: `Client Version:` 行正常输出

- [ ] **Step 2: 安装 minikube**

```bash
curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
sudo install minikube-linux-amd64 /usr/local/bin/minikube
minikube version
```

Expected: `minikube version: v1.x.x`

- [ ] **Step 3: 启动集群**

```bash
minikube start \
  --driver=docker \
  --cpus=4 \
  --memory=6144 \
  --kubernetes-version=stable

kubectl get nodes
```

Expected: `STATUS` 为 `Ready`

- [ ] **Step 4: 启用基础插件**

```bash
minikube addons enable metrics-server
minikube addons list | grep metrics-server
```

Expected: `metrics-server` 显示 `enabled`

- [ ] **Step 5: 验证 Docker 驱动**

```bash
minikube ssh -- docker ps | head -3
```

Expected: 能列出容器，无 permission denied

---

### Task 2: 记录混合网络与 README 骨架

**Files:**
- Create: `iot-learn-lab/infra/k8s/README.md`
- Create: `iot-learn-lab/scripts/stage2/env.sh`

- [ ] **Step 1: 创建 `scripts/stage2/env.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

# WSL → Windows（Phase 1–5：APISIX upstream 指 Windows IDEA 应用）
export WSL_TO_WINDOWS_IP="${WSL_TO_WINDOWS_IP:-$(ip -4 route show default | awk '{print $3}')}"

# Windows → WSL Docker（Windows 浏览器 / IDEA 访问 WSL 中间件）
export WSL_FROM_WINDOWS_IP="${WSL_FROM_WINDOWS_IP:-192.168.19.64}"

# Pod → WSL Docker 中间件（minikube docker driver 首选）
export POD_MIDDLEWARE_HOST="${POD_MIDDLEWARE_HOST:-host.minikube.internal}"

export K8S_NAMESPACE="${K8S_NAMESPACE:-iot-learn}"
export IMAGE_DEVICE_REPORT="${IMAGE_DEVICE_REPORT:-device-report-service:0.1.0-SNAPSHOT}"
export IMAGE_COMMAND_DISPATCH="${IMAGE_COMMAND_DISPATCH:-command-dispatch-service:0.1.0-SNAPSHOT}"
export IMAGE_DEVICE_REPORT_CONSUMER="${IMAGE_DEVICE_REPORT_CONSUMER:-device-report-consumer:0.1.0-SNAPSHOT}"

echo "WSL_TO_WINDOWS_IP=$WSL_TO_WINDOWS_IP"
echo "WSL_FROM_WINDOWS_IP=$WSL_FROM_WINDOWS_IP"
echo "POD_MIDDLEWARE_HOST=$POD_MIDDLEWARE_HOST"
echo "K8S_NAMESPACE=$K8S_NAMESPACE"
```

- [ ] **Step 2: 赋予执行权限**

```bash
chmod +x iot-learn-lab/scripts/stage2/env.sh
```

- [ ] **Step 3: 验证中间件可达（两层）**

```bash
source iot-learn-lab/scripts/stage2/env.sh

# 层 1：WSL 内中间件是否在跑
nc -zv localhost 5432
nc -zv localhost 6379
nc -zv localhost 8848

# 层 2：Pod 视角（部署前必做）
minikube ssh -- nc -zv host.minikube.internal 5432
minikube ssh -- nc -zv host.minikube.internal 6379
minikube ssh -- nc -zv host.minikube.internal 8848
```

Expected: 六个端口均为 `succeeded` 或 `open`。**不要**对 `192.168.16.1` 做 nc 测试来代表 Pod 连通性。

- [ ] **Step 4: 写入 `infra/k8s/README.md` 环境章节**

在 `iot-learn-lab/infra/k8s/README.md` 写入：

```markdown
# Stage 2 K8s 实验环境

## 架构：混合中间件

- **进 minikube：** Java 微服务（本目录 manifest）
- **留 WSL Docker：** PostgreSQL、Redis、Kafka、Nacos、Prometheus、Grafana、APISIX

## 启动 minikube

\`\`\`bash
minikube start --driver=docker --cpus=4 --memory=6144
minikube addons enable metrics-server
\`\`\`

## 网络：Pod → WSL Docker

1. ConfigMap 中 `DB_HOST` / `REDIS_HOST` / `NACOS_ADDR` 使用 **`host.minikube.internal`**（见 `scripts/stage2/env.sh` 的 `POD_MIDDLEWARE_HOST`）
2. WSL 内自检：`nc -zv localhost 5432`
3. Pod 视角自检：`minikube ssh -- nc -zv host.minikube.internal 5432`
4. **不要**把 `192.168.16.1`（WSL→Windows 网关）写入 ConfigMap

## 常用命令

\`\`\`bash
kubectl get pods -n iot-learn
kubectl logs -n iot-learn deploy/device-report-service -f
kubectl port-forward -n iot-learn svc/device-report-service 8765:8765
minikube image load device-report-service:0.1.0-SNAPSHOT
\`\`\`
```

---

### Task 3: `application-k8s.yml`（K8s 配置 profile）

**Files:**
- Create: `iot-learn-lab/device-report-service/src/main/resources/application-k8s.yml`

- [ ] **Step 1: 创建 `application-k8s.yml`**

```yaml
# 激活方式：SPRING_PROFILES_ACTIVE=k8s
# 所有 host 通过环境变量注入，不在镜像内写死 IP
spring:
  datasource:
    url: jdbc:postgresql://${DB_HOST:host.minikube.internal}:${DB_PORT:5432}/iot_learn?options=-c%20TimeZone=Asia/Shanghai
    username: ${DB_USERNAME:postgres}
    password: ${DB_PASSWORD:postgres}
  data:
    redis:
      host: ${REDIS_HOST:host.minikube.internal}
      port: ${REDIS_PORT:6379}
      database: 1
  cloud:
    nacos:
      discovery:
        server-addr: ${NACOS_ADDR:host.minikube.internal:8848}
      config:
        server-addr: ${NACOS_ADDR:host.minikube.internal:8848}
    sentinel:
      transport:
        dashboard: ${SENTINEL_DASHBOARD:host.minikube.internal:8858}

management:
  endpoints:
    web:
      exposure:
        include: health,info,prometheus,metrics
  endpoint:
    health:
      probes:
        enabled: true
```

- [ ] **Step 2: 本地验证 profile 可加载（Windows 或 WSL，需中间件可达）**

```bash
cd iot-learn-lab
# 在 WSL/Windows 本机跑 profile=k8s 时：host.minikube.internal 不可用，
# 必须覆盖全部中间件地址（含 SENTINEL）；W1 可先用 localhost。
DB_HOST=localhost REDIS_HOST=localhost NACOS_ADDR=localhost:8848 \
SENTINEL_DASHBOARD=localhost:8858 \
  mvn spring-boot:run -pl device-report-service \
  -Dspring-boot.run.arguments="--spring.profiles.active=k8s"
```

Expected: 应用启动，`curl http://localhost:8765/actuator/health` 返回 UP（Ctrl+C 停止）。  
Sentinel 连不上时通常只有 WARN，**不一定**让整体 health 失败——W1 本地验证以 health UP + DB/Redis 正常为准；完整 Sentinel 心跳需正确设置 `SENTINEL_DASHBOARD`。

---

### Task 4: device-report-service Dockerfile

**Files:**
- Create: `iot-learn-lab/device-report-service/Dockerfile`
- Create: `iot-learn-lab/device-report-service/.dockerignore`

- [ ] **Step 1: 创建 `.dockerignore`**

```
target/
.idea/
*.iml
.git/
```

- [ ] **Step 2: 创建多阶段 `Dockerfile`**

```dockerfile
# syntax=docker/dockerfile:1

FROM eclipse-temurin:21-jdk-alpine AS builder
WORKDIR /build
COPY pom.xml .
COPY device-report-service/pom.xml device-report-service/
COPY command-dispatch-service/pom.xml command-dispatch-service/
COPY device-report-consumer/pom.xml device-report-consumer/
# 仅下载 device-report-service 依赖（利用 Docker layer cache）
RUN apk add --no-cache maven && \
    mvn -B -pl device-report-service -am dependency:go-offline -DskipTests

COPY device-report-service/src device-report-service/src
COPY command-dispatch-service/src command-dispatch-service/src
COPY device-report-consumer/src device-report-consumer/src
RUN mvn -B -pl device-report-service -am package -DskipTests

FROM eclipse-temurin:21-jre-alpine
WORKDIR /app
# logback 写 /app/log；非 root 用户需预建目录
RUN addgroup -S spring && adduser -S spring -G spring \
    && mkdir -p /app/log \
    && chown -R spring:spring /app
USER spring:spring
COPY --from=builder --chown=spring:spring /build/device-report-service/target/device-report-service-*.jar app.jar

ENV JAVA_OPTS="-XX:MaxRAMPercentage=75.0 -XX:+UseContainerSupport"
ENV SPRING_PROFILES_ACTIVE=k8s

EXPOSE 8765
ENTRYPOINT ["sh", "-c", "java $JAVA_OPTS -jar app.jar"]
```

- [ ] **Step 3: 在 WSL 构建镜像（上下文为 iot-learn-lab 根目录）**

```bash
cd iot-learn-lab
docker build -f device-report-service/Dockerfile -t device-report-service:0.1.0-SNAPSHOT .
```

Expected: 末尾 `exporting to image` 成功

- [ ] **Step 4: 载入 minikube**

```bash
minikube image load device-report-service:0.1.0-SNAPSHOT
minikube ssh -- docker images | grep device-report
```

Expected: 镜像列表中有 `device-report-service`

---

### Task 5: 其余两模块 Dockerfile（W1 仅 build，W2 部署）

> K8s / Task 5–6 概念讲解见：`docs/superpowers/guides/2026-07-14-stage2-w1-k8s-primer.md`

**Files:**
- Create: `iot-learn-lab/command-dispatch-service/Dockerfile`
- Create: `iot-learn-lab/command-dispatch-service/.dockerignore`
- Create: `iot-learn-lab/device-report-consumer/Dockerfile`
- Create: `iot-learn-lab/device-report-consumer/.dockerignore`

- [ ] **Step 1: `command-dispatch-service/Dockerfile`**

```dockerfile
FROM eclipse-temurin:21-jdk-alpine AS builder
WORKDIR /build
COPY pom.xml .
COPY device-report-service/pom.xml device-report-service/
COPY command-dispatch-service/pom.xml command-dispatch-service/
COPY device-report-consumer/pom.xml device-report-consumer/
RUN apk add --no-cache maven && \
    mvn -B -pl command-dispatch-service -am dependency:go-offline -DskipTests
COPY device-report-service/src device-report-service/src
COPY command-dispatch-service/src command-dispatch-service/src
COPY device-report-consumer/src device-report-consumer/src
RUN mvn -B -pl command-dispatch-service -am package -DskipTests

FROM eclipse-temurin:21-jre-alpine
WORKDIR /app
RUN addgroup -S spring && adduser -S spring -G spring \
    && mkdir -p /app/log \
    && chown -R spring:spring /app
USER spring:spring
COPY --from=builder --chown=spring:spring /build/command-dispatch-service/target/command-dispatch-service-*.jar app.jar
ENV JAVA_OPTS="-XX:MaxRAMPercentage=75.0 -XX:+UseContainerSupport"
ENV SPRING_PROFILES_ACTIVE=k8s
EXPOSE 8767
ENTRYPOINT ["sh", "-c", "java $JAVA_OPTS -jar app.jar"]
```

- [ ] **Step 2: `device-report-consumer/Dockerfile`**

```dockerfile
FROM eclipse-temurin:21-jdk-alpine AS builder
WORKDIR /build
COPY pom.xml .
COPY device-report-service/pom.xml device-report-service/
COPY command-dispatch-service/pom.xml command-dispatch-service/
COPY device-report-consumer/pom.xml device-report-consumer/
RUN apk add --no-cache maven && \
    mvn -B -pl device-report-consumer -am dependency:go-offline -DskipTests
COPY device-report-service/src device-report-service/src
COPY command-dispatch-service/src command-dispatch-service/src
COPY device-report-consumer/src device-report-consumer/src
RUN mvn -B -pl device-report-consumer -am package -DskipTests

FROM eclipse-temurin:21-jre-alpine
WORKDIR /app
RUN addgroup -S spring && adduser -S spring -G spring \
    && mkdir -p /app/log \
    && chown -R spring:spring /app
USER spring:spring
COPY --from=builder --chown=spring:spring /build/device-report-consumer/target/device-report-consumer-*.jar app.jar
ENV JAVA_OPTS="-XX:MaxRAMPercentage=75.0 -XX:+UseContainerSupport"
ENV SPRING_PROFILES_ACTIVE=k8s
EXPOSE 8768
ENTRYPOINT ["sh", "-c", "java $JAVA_OPTS -jar app.jar"]
```

- [ ] **Step 3: 构建验证（可选，确认 Dockerfile 无语法错误）**

```bash
cd iot-learn-lab
docker build -f command-dispatch-service/Dockerfile -t command-dispatch-service:0.1.0-SNAPSHOT .
docker build -f device-report-consumer/Dockerfile -t device-report-consumer:0.1.0-SNAPSHOT .
```

Expected: 两个镜像 build 成功

---

### Task 6: K8s Namespace + ConfigMap + Deployment + Service

**Files:**
- Create: `iot-learn-lab/infra/k8s/namespace.yaml`
- Create: `iot-learn-lab/infra/k8s/device-report/configmap-env.yaml`
- Create: `iot-learn-lab/infra/k8s/device-report/deployment.yaml`
- Create: `iot-learn-lab/infra/k8s/device-report/service.yaml`

- [ ] **Step 1: `namespace.yaml`**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: iot-learn
  labels:
    app.kubernetes.io/part-of: iot-learn-lab
```

- [ ] **Step 2: `configmap-env.yaml`（默认使用 `host.minikube.internal`）**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: device-report-middleware
  namespace: iot-learn
data:
  # Pod → WSL Docker；与 scripts/stage2/env.sh 中 POD_MIDDLEWARE_HOST 一致
  # 部署前已验证: minikube ssh -- nc -zv host.minikube.internal 5432
  DB_HOST: "host.minikube.internal"
  DB_PORT: "5432"
  DB_USERNAME: "postgres"
  DB_PASSWORD: "postgres"
  REDIS_HOST: "host.minikube.internal"
  REDIS_PORT: "6379"
  NACOS_ADDR: "192.168.19.64:8848"
  SENTINEL_DASHBOARD: "host.minikube.internal:8858"
  SPRING_PROFILES_ACTIVE: "k8s"
```

> **Nacos 补充：**  
> 1) `JAVA_OPT_EXT` 会被拼到 **`-jar` 之后**，`-Dnacos.inetutils...` **不会**成为 JVM 参数（这是一直连 `127.0.0.1:9848` 的常见原因）。请改用 `JAVA_OPT: "-Dnacos.inetutils.ip-address=192.168.19.64"`，或在挂载的 `conf/application.properties` 写 `nacos.inetutils.ip-address=192.168.19.64`。  
> 2) 默认 `application.yml` 的 `optional:nacos` import 会强制起 `*_config-0` 客户端；已挪到仅 `application-v2.yml`。W1 的 `application-k8s.yml` 关闭 discovery/config。  
> 3) 改 yml 后必须 rebuild + `minikube image rm/load` 再 apply。

- [ ] **Step 3: `deployment.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: device-report-service
  namespace: iot-learn
  labels:
    app: device-report-service
spec:
  replicas: 1
  selector:
    matchLabels:
      app: device-report-service
  template:
    metadata:
      labels:
        app: device-report-service
        version: v1
    spec:
      containers:
        - name: device-report-service
          image: device-report-service:0.1.0-SNAPSHOT
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8765
              name: http
          envFrom:
            - configMapRef:
                name: device-report-middleware
          readinessProbe:
            httpGet:
              path: /actuator/health/readiness
              port: 8765
            initialDelaySeconds: 30
            periodSeconds: 10
            failureThreshold: 6
          livenessProbe:
            httpGet:
              path: /actuator/health/liveness
              port: 8765
            initialDelaySeconds: 60
            periodSeconds: 20
          resources:
            requests:
              memory: "512Mi"
              cpu: "250m"
            limits:
              memory: "1Gi"
              cpu: "1000m"
```

- [ ] **Step 4: `service.yaml`**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: device-report-service
  namespace: iot-learn
  labels:
    app: device-report-service
spec:
  type: ClusterIP
  selector:
    app: device-report-service
  ports:
    - name: http
      port: 8765
      targetPort: 8765
```

- [ ] **Step 5: apply 全部 manifest**

```bash
kubectl apply -f iot-learn-lab/infra/k8s/namespace.yaml
kubectl apply -f iot-learn-lab/infra/k8s/device-report/configmap-env.yaml
kubectl apply -f iot-learn-lab/infra/k8s/device-report/deployment.yaml
kubectl apply -f iot-learn-lab/infra/k8s/device-report/service.yaml
```

Expected: 四个资源 `created` 或 `configured`

- [ ] **Step 6: 等待 Pod Ready**

```bash
kubectl rollout status deployment/device-report-service -n iot-learn --timeout=180s
kubectl get pods -n iot-learn -o wide
```

Expected: `READY 1/1`，`STATUS Running`

---

### Task 7: 场景 K1 验证脚本

**Files:**
- Create: `iot-learn-lab/scripts/stage2/scenario-k1-k8s-baseline.sh`

- [ ] **Step 1: 创建验证脚本**

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "${SCRIPT_DIR}/env.sh"

NS="${K8S_NAMESPACE}"
SVC="device-report-service"
LOCAL_PORT=8765

echo "== K1: device-report-service on minikube =="

kubectl get pods -n "$NS" -l app="$SVC"
kubectl rollout status deployment/"$SVC" -n "$NS" --timeout=120s

kubectl port-forward -n "$NS" "svc/${SVC}" "${LOCAL_PORT}:8765" &
PF_PID=$!
trap 'kill $PF_PID 2>/dev/null || true' EXIT
sleep 3

echo "-- health --"
curl -sf "http://127.0.0.1:${LOCAL_PORT}/actuator/health" | head -c 200
echo

echo "-- POST /api/v1/reports --"
DEVICE_ID="k8s-baseline-$(date +%s)"
curl -sf -X POST "http://127.0.0.1:${LOCAL_PORT}/api/v1/reports" \
  -H "Content-Type: application/json" \
  -d "{\"deviceId\":\"${DEVICE_ID}\",\"payload\":{\"temp\":25}}"

echo
echo "K1 PASS: Pod 健康且同步上报 201"
```

- [ ] **Step 2: 执行脚本**

```bash
chmod +x iot-learn-lab/scripts/stage2/scenario-k1-k8s-baseline.sh
iot-learn-lab/scripts/stage2/scenario-k1-k8s-baseline.sh
```

Expected: 输出 `K1 PASS`

- [ ] **Step 3: 失败时排查命令（记入 README Troubleshooting）**

```bash
kubectl describe pod -n iot-learn -l app=device-report-service
kubectl logs -n iot-learn -l app=device-report-service --tail=100
# Pod 内测试 DB 连通：
kubectl exec -n iot-learn deploy/device-report-service -- \
  wget -qO- "http://127.0.0.1:8765/actuator/health" || true
```

**常见踩坑：**

| 现象 | 原因 | 处理 |
|------|------|------|
| `ImagePullBackOff` | 镜像未 load 进 minikube | `minikube image load device-report-service:0.1.0-SNAPSHOT` |
| `CrashLoopBackOff` | 先看 `kubectl logs`，不要先猜 DB | 日志有 `/app/log` 则修 Dockerfile 预建目录；有 DB 连接失败再查 ConfigMap / `host.minikube.internal` |
| 日志 `/app/log ... No such file` | 非 root 无法创建日志目录 | Dockerfile：`mkdir -p /app/log && chown`；重建并 `minikube image load` |
| ConfigMap 用了 `192.168.16.1` | 误用 WSL→Windows 网关 | 改为 `host.minikube.internal` |
| readiness 超时 | 启动慢于 30s | 调大 `initialDelaySeconds` 或看日志 |
| Nacos `nc` 通但日志 `127.0.0.1:9848` / `*_config-0` | ① 服务端宣告 loopback；② `JAVA_OPT_EXT` 的 `-D` 在 `-jar` 后无效；③ 默认 `optional:nacos` import | compose 用 `JAVA_OPT=-Dnacos.inetutils.ip-address=192.168.19.64`；import 挪到 v2；W1 关 discovery/config；改完 restart/rebuild。详见 `infra/k8s/README.md` |
| 改完 Nacos 仍连 `127.0.0.1` | 旧 JVM 缓存错误服务端列表 | `kubectl rollout restart deployment/...` |
| Nacos 对 K1 | 非阻塞 | W1 健康检查/上报可不依赖 Nacos |

> ConfigMap 完整版与原因说明：`iot-learn-lab/infra/k8s/README.md`「踩坑实录：Nacos」。

---

### Task 8: W1 复盘文档骨架

**Files:**
- Create: `iot-learn-lab/docs/stage2-interview-notes.md`

- [ ] **Step 1: 创建面试笔记骨架**

```markdown
# Stage 2 面试复盘笔记

**日期：** 2026-07-13 起  
**架构：** 混合中间件（应用 K8s + 中间件 WSL Docker）

## W1 场景记录

| 场景 | 日期 | 通过？ | 关键现象 |
|------|------|--------|----------|
| K1 K8s 基线 | | ☐ | Pod Ready；port-forward health UP；201 上报 |

## W1 面试题自测

1. Pod 和 Deployment 区别？
2. liveness 和 readiness 区别？
3. 混合部署时 Pod 如何访问 WSL 上的 PostgreSQL？
4. 为什么 Dockerfile 用多阶段构建？
5. `imagePullPolicy: IfNotPresent` 在 minikube 本地镜像场景的作用？

## 踩坑记录

| 踩坑 | 原因 | 处理 |
|------|------|------|
| | | |
```

---

## W1 完成标准（Checklist）

- [ ] `minikube start` 成功，`kubectl get nodes` Ready
- [ ] 3 个 Dockerfile 存在且 `device-report-service` 镜像 build + load 成功
- [ ] `application-k8s.yml` 可通过环境变量覆盖中间件地址
- [ ] `device-report-service` Deployment `1/1 Running`
- [ ] `scenario-k1-k8s-baseline.sh` 输出 `K1 PASS`
- [ ] `infra/k8s/README.md` 含启动命令与排障表
- [ ] `stage2-interview-notes.md` W1 章节已填截图/现象

---

## W1 面试话术速记

| 问题 | 答法 |
|------|------|
| 为什么中间件不迁 K8s？ | WSL 资源有限；渐进学习；Phase 1–5 脚本复用；生产可再迁 |
| Pod 连宿主机 DB？ | `host.minikube.internal` + ConfigMap 注入；解析后常为 `192.168.49.1`；勿用 `192.168.16.1` |
| 容器 JVM 内存？ | `-XX:MaxRAMPercentage=75` + limits 防止 OOMKill |
| 本地镜像怎么给 minikube 用？ | `docker build` 后 `minikube image load` |

---

## 下一步（W2 预告）

- 为 `command-dispatch-service`、`device-report-consumer` 增加 `application-k8s.yml`
- 部署两服务；Feign 改用 K8s Service DNS
- Kafka `SPRING_KAFKA_BOOTSTRAP_SERVERS` 指向 `host.minikube.internal:9092`（或 `POD_MIDDLEWARE_HOST:9092`）
- 脚本：`scenario-k2-three-services.sh`

**W2 实施计划文件：** `docs/superpowers/plans/2026-07-16-stage2-w2-three-services.md`  
**W2 前置指南：** `docs/superpowers/guides/2026-07-16-stage2-w2-service-dns-kafka.md`

---

## Spec 覆盖自检

| Spec 要求（Stage 2 W1 段） | 本计划 Task |
|---------------------------|-------------|
| minikube 安装 | Task 1 |
| 混合网络约定 | Task 2 |
| Dockerfile 三模块 | Task 4–5 |
| application-k8s profile | Task 3 |
| 首个服务 Deployment | Task 6 |
| K1 基线验证 | Task 7 |
| 复盘文档 | Task 8 |

---

## 执行方式

**Plan complete and saved to `docs/superpowers/plans/2026-07-13-stage2-w1-minikube-dockerfile.md`. Two execution options:**

1. **Subagent-Driven（推荐）** — 按 Task 派发子代理，每 Task 后 review  
2. **Inline Execution** — 本会话按 Task 1→8 连续执行，Checkpoint 在 Task 6 后

**Which approach?**
