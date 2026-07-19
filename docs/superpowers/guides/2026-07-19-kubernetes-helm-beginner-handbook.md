# Kubernetes 与 Helm 零基础入门手册

**适合读者：** 有 Java / Spring Boot 开发经验，但没有 Kubernetes、kubectl、minikube、Helm 使用经验的开发人员
**实验环境：** Windows + WSL2 + Docker + minikube（Docker driver）
**项目示例：** `iot-learn-lab` 三个 Java 服务 + WSL Docker 中间件
**学习目标：** 不只会复制命令，而是能解释每个组件为什么存在、配置如何生效、故障应从哪里查起

---

## 先看最终要完成什么

完成本手册后，你会得到下面这条可运行链路：

```text
Java 源码
   │ mvn package
   ▼
JAR
   │ docker build
   ▼
容器镜像
   │ minikube image load
   ▼
minikube 节点中的镜像
   │ kubectl apply / helm upgrade --install
   ▼
Deployment → ReplicaSet → Pod
                           │
                           ├─ ConfigMap 注入 Spring 环境变量
                           ├─ Service 提供稳定地址
                           └─ Ingress 按 Host / Path 转发 HTTP
```

当前项目采用“混合中间件”：

```text
┌─ minikube（Kubernetes）──────────────────────────────────────┐
│ device-report-service                                       │
│ command-dispatch-service                                    │
│ device-report-consumer                                      │
│ Service / Ingress / ConfigMap                               │
└──────────────────────┬──────────────────────────────────────┘
                       │ host.minikube.internal / WSL IP
┌──────────────────────▼──────────────────────────────────────┐
│ WSL Docker                                                    │
│ PostgreSQL · Redis · Kafka · Nacos · Prometheus · Grafana   │
└─────────────────────────────────────────────────────────────┘
```

也就是说：本手册学习的是如何把 **Java 应用**放进 Kubernetes；不是把所有数据库和中间件一次性迁进去。

---

## 0. 学习方法与推荐资料

这类工具最容易学成“背命令”。更可靠的方式是抓住三个心智模型。

### 0.1 期望状态与调和（Reconciliation）

你提交的 YAML 不是一串一次性脚本，而是“我希望系统最终变成什么样”。控制器持续比较：

```text
期望状态：replicas = 2
实际状态：只有 1 个 Pod
差异：少 1 个
动作：创建 1 个 Pod
```

这解释了为什么删掉 Deployment 管理的 Pod 后，它会自动回来。

### 0.2 API 对象与职责分离

Kubernetes 不用一个巨型配置描述一切，而是拆成多个对象：

- Deployment 负责应用副本与滚动更新。
- Service 负责稳定访问地址。
- ConfigMap 负责非敏感配置。
- Ingress 负责 HTTP(S) 入口规则。

对象之间通过 Label / Selector 连接。排障时也沿着这条关系逐层检查。

### 0.3 Helm“先渲染，再调和”

Helm 不取代 Kubernetes：

```text
Values + Templates
        │ Helm 渲染
        ▼
普通 Kubernetes YAML
        │ 提交 API Server
        ▼
Kubernetes 控制器调和
```

推荐深入阅读：

1. [Kubernetes 官方概念文档](https://kubernetes.io/docs/concepts/)：术语与行为的权威来源。
2. *Kubernetes: Up and Running*，Kelsey Hightower、Brendan Burns、Joe Beda：从应用开发者视角建立整体模型。
3. [Helm 官方文档](https://helm.sh/docs/)：模板函数、Values 优先级和 Release 生命周期以官方文档为准。

---

# 第一部分：工具边界

## 1. Docker、Kubernetes、minikube、kubectl、Helm 分别做什么

### 1.1 Docker

Docker 在本项目中主要负责两件事：

1. 根据 Dockerfile 构建镜像。
2. 在 WSL 中运行 PostgreSQL、Redis、Kafka 等中间件。

```bash
docker build \
  -f device-report-service/Dockerfile \
  -t device-report-service:0.1.0-SNAPSHOT \
  .

docker images
docker ps
```

Docker 解决“怎么把一个程序和运行环境打包并启动”。它本身不负责跨节点调度、自动补副本、Service 发现或声明式滚动发布。

### 1.2 Kubernetes

Kubernetes 是管理容器化工作负载的平台。它负责：

- 把 Pod 调度到节点。
- 保持指定副本数。
- 失败后重建 Pod。
- 提供 Service 发现和负载分发。
- 执行滚动更新与回滚。
- 管理配置、Secret、存储和入口规则。

Kubernetes 不是：

- Docker 镜像构建工具；
- Java 配置中心；
- 数据库；
- 自动包含 Prometheus、Kafka、Nacos 的完整 PaaS。

它提供的是可组合的基础能力。

### 1.3 minikube

minikube 是在本地创建学习用 Kubernetes 集群的工具。

```bash
minikube start --driver=docker --cpus=4 --memory=6144
```

在当前 WSL 环境里，minikube 使用 Docker driver 创建一个单节点集群。这个节点同时承担控制面和工作节点职责。

minikube 负责：

- 创建、启动、停止和删除本地集群；
- 配置 kubectl context；
- 管理本地 addon；
- 把本地镜像载入集群节点；
- 提供 `minikube ip`、`minikube ssh` 等本地便利能力。

minikube 不是生产集群发行版。它的主要价值是低成本学习和本地验证。

### 1.4 kubectl

kubectl 是 Kubernetes API 客户端。它读取 kubeconfig，连接 API Server。

```bash
kubectl get nodes
kubectl apply -f deployment.yaml
kubectl logs -n iot-learn deploy/device-report-service
```

kubectl 不创建 Kubernetes 集群；它操作一个已经存在的集群。若 kubeconfig 没配置好，常见报错是尝试连接 `localhost:8080`。

### 1.5 Helm

Helm 是 Kubernetes 包管理器和模板渲染工具。

裸 YAML 方式：

```bash
kubectl apply -f configmap.yaml
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml
kubectl apply -f ingress.yaml
```

Helm 方式：

```bash
helm upgrade --install iot-learn \
  iot-learn-lab/infra/helm/iot-learn-lab \
  -n iot-learn \
  -f iot-learn-lab/infra/helm/iot-learn-lab/values.yaml \
  -f iot-learn-lab/infra/helm/iot-learn-lab/values-v1.yaml \
  --wait
```

Helm 将参数填入模板，生成 Kubernetes YAML，然后提交给 Kubernetes。它还记录 Release 历史，支持升级和回滚。

### 1.6 一张职责表

| 工具 / 系统 | 管什么 | 典型输入 | 典型输出 |
|-------------|--------|----------|----------|
| Maven | Java 构建 | `pom.xml`、源码 | JAR |
| Docker | 镜像与容器 | Dockerfile | 镜像 / 容器 |
| minikube | 本地集群生命周期 | 启动参数 / profile | 本地 K8s 集群 |
| kubectl | Kubernetes API 对象 | manifest / 命令 | 集群对象变化 |
| Kubernetes | 调度与调和 | API 对象期望状态 | Pod、Service 等实际状态 |
| Helm | YAML 模板化和 Release | Chart + Values | 渲染 YAML + Release 历史 |

---

# 第二部分：Kubernetes 集群由什么组成

## 2. 集群的基本结构

生产 Kubernetes 集群通常包含：

```text
┌─ Control Plane ──────────────────────────────┐
│ kube-apiserver                               │
│ etcd                                         │
│ kube-scheduler                               │
│ kube-controller-manager                      │
└──────────────────────────────────────────────┘
             │
             │ Kubernetes API
             ▼
┌─ Worker Node ────────────────────────────────┐
│ kubelet                                      │
│ container runtime                            │
│ kube-proxy 或等价网络实现                    │
│ Pod / Pod / Pod                              │
└──────────────────────────────────────────────┘
```

minikube 默认是单节点：同一个节点既运行控制面组件，也运行工作负载。

## 3. 控制面组件

### 3.1 kube-apiserver

API Server 是 Kubernetes 的统一入口。

以下操作都会经过它：

- `kubectl apply`
- `kubectl get`
- Scheduler 读取未调度 Pod
- Controller 更新对象状态
- kubelet 汇报节点与 Pod 状态

它负责 API 暴露、认证、授权、准入和对象校验。其他组件通常不直接读写 etcd，而是通过 API Server 协作。

### 3.2 etcd

etcd 是保存集群数据的一致性键值存储。

它存的是 Kubernetes 对象状态，例如：

- Deployment 的期望副本数；
- Service 的定义；
- ConfigMap 内容；
- Pod 当前状态。

不要把 etcd 理解成应用业务数据库。你的 `device_report` 业务数据仍在 PostgreSQL。

### 3.3 kube-scheduler

Scheduler 关注“新 Pod 应该放到哪个节点”。

它会考虑：

- 节点剩余 CPU / 内存；
- Pod 的 resources requests；
- 污点与容忍；
- 亲和性 / 反亲和性；
- 节点选择约束。

Scheduler 只决定节点，不负责在节点上启动容器。

### 3.4 kube-controller-manager

Controller Manager 运行多个控制循环。例如 Deployment / ReplicaSet 相关控制器会持续比较实际状态与期望状态。

```text
Deployment replicas=2
       │
       ▼
ReplicaSet 期望 2 个 Pod
       │
       ├─ Pod A Running
       └─ Pod B 不存在 → 创建
```

“自动恢复”本质上不是魔法，而是控制器持续调和。

## 4. 节点组件

### 4.1 kubelet

kubelet 是每个节点上的代理。它取得分配给该节点的 PodSpec，并确保对应容器运行和健康。

它关注：

- 容器是否启动；
- 探针结果；
- Pod 状态；
- 挂载配置与存储；
- 向 API Server 汇报状态。

### 4.2 容器运行时

容器运行时真正负责拉取镜像、创建和停止容器。常见实现包括 containerd、CRI-O。

不要把“minikube 使用 Docker driver”和“节点里的容器运行时”混成一件事：

- driver 决定 minikube 节点运行在哪里；
- container runtime 决定节点如何运行 Pod 容器。

### 4.3 kube-proxy 与 Service 网络

kube-proxy（或网络插件提供的等价实现）维护 Service 转发规则，使一个稳定的 Service 地址能够把流量发到后端 Ready Pod。

```text
Service: command-dispatch-service:8767
             │ selector: app=command-dispatch-service
             ▼
Endpoints / EndpointSlice
             ├─ Pod IP A:8767
             └─ Pod IP B:8767
```

### 4.4 CNI 与 CSI

Kubernetes 规定接口，不把所有底层实现写死：

- **CNI（Container Network Interface）**：网络插件接口，负责给 Pod 分配网络并实现 Pod 间通信。常见实现有 Calico、Cilium、Flannel。
- **CSI（Container Storage Interface）**：存储插件接口，让 Kubernetes 可以挂载不同厂商或类型的存储。
- **CRI（Container Runtime Interface）**：容器运行时接口，kubelet 通过它驱动 containerd、CRI-O 等运行时。

初学阶段不需要自己开发这些插件，但要知道：Kubernetes 的 Service、Pod 网络和持久卷背后依赖具体实现，不是 API 对象凭空产生数据通路。

### 4.5 CoreDNS

CoreDNS 为集群内 Service 提供 DNS。

同 Namespace 可使用短名：

```text
http://command-dispatch-service:8767
```

完整名称：

```text
command-dispatch-service.iot-learn.svc.cluster.local
```

### 4.6 Ingress Controller

Ingress 只是一组路由规则；真正接收流量并执行规则的是 Ingress Controller。

当前项目启用：

```bash
minikube addons enable ingress
```

它安装 ingress-nginx controller。没有 Controller，单独创建 Ingress 对象不会自动产生 HTTP 入口。

## 5. `kubectl apply` 后发生什么

以 Deployment 为例：

```text
1. kubectl 读取 YAML
2. kubectl 将对象发送给 API Server
3. API Server 校验并把期望状态持久化
4. Deployment Controller 创建 / 更新 ReplicaSet
5. ReplicaSet Controller 创建缺少的 Pod
6. Scheduler 给未绑定 Pod 选择节点
7. 节点 kubelet 调用容器运行时启动容器
8. kubelet 执行探针并上报状态
9. Service 根据 selector 选择 Ready Pod
```

因此 `kubectl apply` 成功，只能说明对象已被 API Server 接收，不代表应用已经 Ready。还要检查：

```bash
kubectl rollout status deployment/device-report-service \
  -n iot-learn --timeout=180s
```

---

# 第三部分：从零创建本地集群

## 6. 前置检查

在 WSL 终端执行：

```bash
docker version
docker ps
free -h
df -h
```

当前项目建议：

- 至少 4 CPU；
- minikube 分配约 6 GB 内存；
- 保留足够磁盘存放镜像；
- Docker daemon 正常。

检查工具：

```bash
kubectl version --client
minikube version
helm version
```

安装方式会随版本变化，优先采用官方文档：

- kubectl：https://kubernetes.io/docs/tasks/tools/
- minikube：https://minikube.sigs.k8s.io/docs/start/
- Helm：https://helm.sh/docs/intro/install/

## 7. 启动集群

```bash
minikube start \
  --driver=docker \
  --cpus=4 \
  --memory=6144 \
  --kubernetes-version=stable
```

参数含义：

| 参数 | 含义 | 当前项目为什么这样设 |
|------|------|----------------------|
| `--driver=docker` | 用现有 Docker 承载 minikube 节点 | 与 WSL Docker 环境一致 |
| `--cpus=4` | 为节点分配 4 CPU | 三个 Java 服务 + 系统组件 |
| `--memory=6144` | 为节点分配约 6 GB | 避免 JVM 与系统 Pod 过度争抢 |
| `--kubernetes-version=stable` | 使用稳定版 Kubernetes | 学习环境减少版本不确定性 |

也可以持久化默认值：

```bash
minikube config set driver docker
minikube config set cpus 4
minikube config set memory 6144
minikube config view
```

命令行显式参数适合项目文档和可重复实验；持久配置适合个人默认环境。

## 8. kubeconfig 与 context

minikube 启动后会把连接信息写入 kubeconfig（通常为 `~/.kube/config`）。

kubeconfig 包含三类信息：

- cluster：API Server 地址和 CA；
- user：访问凭据；
- context：把 cluster、user、默认 Namespace 组合起来。

检查：

```bash
kubectl config get-contexts
kubectl config current-context
kubectl cluster-info
```

期望当前 context 是 `minikube`。

切换 context：

```bash
kubectl config use-context minikube
```

设置当前 context 的默认 Namespace（可选）：

```bash
kubectl config set-context --current --namespace=iot-learn
```

初学阶段仍建议命令显式写 `-n iot-learn`，避免误操作其他 Namespace。

## 9. 启用 addon

```bash
minikube addons list
minikube addons enable metrics-server
minikube addons enable ingress
```

作用：

| addon | 用途 |
|-------|------|
| `metrics-server` | 提供基础 CPU / 内存指标，支持 `kubectl top`；不是 Prometheus |
| `ingress` | 安装 Ingress Controller，执行 Ingress 路由 |

验证：

```bash
kubectl get pods -A
kubectl get pods -n ingress-nginx
kubectl top nodes
```

`metrics-server` 启动后可能需要短暂等待，`kubectl top` 才有数据。

## 10. 集群生命周期命令

| 命令 | 作用 | 数据是否保留 |
|------|------|--------------|
| `minikube pause` | 暂停集群进程 | 保留 |
| `minikube unpause` | 恢复暂停集群 | 保留 |
| `minikube stop` | 停止集群 | 保留 |
| `minikube start` | 启动 / 恢复集群 | 原 profile 通常保留 |
| `minikube delete` | 删除当前集群 | 不保留集群对象 |
| `minikube delete --all` | 删除所有 profile | 高风险 |

查看 profile：

```bash
minikube profile list
minikube status
```

需要多个独立实验集群时：

```bash
minikube start -p iot-lab --driver=docker
minikube profile iot-lab
```

---

# 第四部分：Kubernetes 对象模型

## 11. Namespace

Namespace 是集群内的逻辑隔离范围。

当前项目：

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: iot-learn
```

使用：

```bash
kubectl apply -f iot-learn-lab/infra/k8s/namespace.yaml
kubectl get namespace
kubectl get all -n iot-learn
```

Namespace 不是强安全边界。生产隔离还需要 RBAC、NetworkPolicy、ResourceQuota 等。

## 12. Pod

Pod 是 Kubernetes 调度的最小单位，可以包含一个或多个共享网络与存储的容器。

常规 Java 服务通常一个 Pod 放一个主业务容器。不要直接手写长期运行 Pod，因为：

- 没有副本管理；
- 删除后不会由 Deployment 自动补；
- 不方便滚动升级。

查看：

```bash
kubectl get pods -n iot-learn -o wide
kubectl describe pod -n iot-learn <pod-name>
```

## 13. Deployment 与 ReplicaSet

Deployment 管理无状态应用的发布，ReplicaSet 管理具体 Pod 副本。

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: device-report-service
  namespace: iot-learn
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
```

关系：

```text
Deployment
  └─ ReplicaSet（某个 Pod 模板版本）
       ├─ Pod
       └─ Pod
```

修改 Pod 模板（镜像、环境变量引用、标签等）通常会创建新 ReplicaSet 并滚动更新。

```bash
kubectl get deployment,replicaset,pod -n iot-learn
kubectl rollout status deployment/device-report-service -n iot-learn
kubectl rollout history deployment/device-report-service -n iot-learn
kubectl rollout undo deployment/device-report-service -n iot-learn
```

Kubernetes 还会通过 `metadata.ownerReferences` 记录“谁拥有谁”。例如 ReplicaSet 通常归 Deployment 所有，Pod 归 ReplicaSet 所有。删除上层对象时，垃圾回收机制可据此清理下层对象。Owner Reference 不是流量选择器；Service 仍靠 Label / Selector 找 Pod。

## 14. Label、Selector 与 Annotation

Label 是可用于选择对象的键值对：

```yaml
labels:
  app: device-report-service
  version: v1
```

Selector 使用 Label 建立关系：

```yaml
selector:
  matchLabels:
    app: device-report-service
```

本项目中有两条重要连接：

1. Deployment selector → 自己管理的 Pod template label；
2. Service selector → 要转发到的 Pod label。

Selector 写错时，Service 仍可能存在，但没有后端 Endpoint。

```bash
kubectl get pods -n iot-learn --show-labels
kubectl get pods -n iot-learn -l app=device-report-service
kubectl get endpoints,endpointslices -n iot-learn
```

Annotation 也是键值元数据，但通常用于工具配置而非筛选，例如：

```yaml
annotations:
  nginx.ingress.kubernetes.io/proxy-body-size: "2m"
```

## 15. Service

Pod IP 会随重建改变。Service 提供稳定虚拟地址和 DNS。

当前项目：

```yaml
apiVersion: v1
kind: Service
metadata:
  name: device-report-service
  namespace: iot-learn
spec:
  type: NodePort
  selector:
    app: device-report-service
  ports:
    - name: http
      port: 8765
      targetPort: 8765
      nodePort: 30765
```

端口含义：

```text
集群内客户端
    │ Service port: 8765
    ▼
Service
    │ targetPort: 8765
    ▼
Pod 容器端口 8765

集群外客户端
    │ NodeIP:nodePort（minikube IP:30765）
    ▼
同一个 Service
```

Service 类型：

| 类型 | 含义 | 适用场景 |
|------|------|----------|
| ClusterIP | 只提供集群内地址 | 默认；内部微服务 |
| NodePort | 在每个节点开放固定高位端口 | 本地实验、简单外部访问 |
| LoadBalancer | 请求基础设施创建负载均衡器 | 云环境常用；本地需额外实现 |
| ExternalName | DNS CNAME 指向外部域名 | 少量外部服务映射 |

查看：

```bash
kubectl get svc -n iot-learn
kubectl describe svc device-report-service -n iot-learn
kubectl get endpoints device-report-service -n iot-learn
```

## 16. Ingress

Ingress 是 HTTP(S) 七层路由规则。

当前项目：

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: device-report-ingress
  namespace: iot-learn
spec:
  ingressClassName: nginx
  rules:
    - host: device-report.iot-learn.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: device-report-service
                port:
                  number: 8765
```

请求链路：

```text
HTTP Host=device-report.iot-learn.local
        │
        ▼
ingress-nginx controller
        │ 匹配 host + path
        ▼
device-report-service:8765
        │
        ▼
Ready Pod
```

验证：

```bash
MINIKUBE_IP="$(minikube ip)"
curl -H "Host: device-report.iot-learn.local" \
  "http://${MINIKUBE_IP}/actuator/health"
```

只请求 IP 而不带 Host，规则可能不匹配并返回 404。

## 17. ConfigMap 与 Secret

ConfigMap 保存非敏感配置。当前项目通过 `envFrom` 把 ConfigMap 的所有键注入容器环境变量：

```yaml
envFrom:
  - configMapRef:
      name: device-report-middleware
```

ConfigMap 示例：

```yaml
data:
  DB_HOST: "host.minikube.internal"
  DB_PORT: "5432"
  REDIS_HOST: "host.minikube.internal"
  KAFKA_BOOTSTRAP: "host.minikube.internal:9092"
  DISPATCH_BASE_URL: "http://command-dispatch-service:8767"
  SPRING_PROFILES_ACTIVE: "k8s"
```

Spring Boot 读取链路：

```text
ConfigMap DB_HOST
   │ envFrom
   ▼
容器环境变量 DB_HOST
   │ ${DB_HOST:默认值}
   ▼
application-k8s.yml
   ▼
spring.datasource.url
```

ConfigMap 改了，已运行容器的环境变量不会自动变化：

```bash
kubectl apply -f configmap-env.yaml
kubectl rollout restart deployment/device-report-service -n iot-learn
```

Secret 用于敏感配置，但要注意：Kubernetes Secret 默认只是 base64 编码，不等于加密。生产还应结合：

- etcd 静态加密；
- RBAC 最小权限；
- External Secrets / Vault / 云密钥系统；
- 避免把真实密码提交 Git。

当前 `values.yaml` 里的 PostgreSQL 密码仅用于本地学习，不是生产最佳实践。

## 18. 探针

### readinessProbe

回答：“这个 Pod 现在能接收流量吗？”

失败后：

- Pod 仍可能 Running；
- 从 Service 后端移除；
- 不一定重启容器。

### livenessProbe

回答：“这个容器是否已经卡死，需要重启？”

连续失败达到阈值后，kubelet 重启容器。

### startupProbe

回答：“应用是否还在启动阶段？”

适合启动很慢的应用。startupProbe 成功前，liveness/readiness 不接管，避免 Java 冷启动时被误杀。

当前项目：

```yaml
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
```

关键字段：

| 字段 | 含义 |
|------|------|
| `initialDelaySeconds` | 容器启动后等待多久再首次探测 |
| `periodSeconds` | 探测间隔 |
| `timeoutSeconds` | 单次超时（未写时使用默认值） |
| `failureThreshold` | 连续失败多少次判定失败 |
| `successThreshold` | 连续成功多少次判定恢复 |

## 19. resources requests 与 limits

```yaml
resources:
  requests:
    memory: "512Mi"
    cpu: "250m"
  limits:
    memory: "1Gi"
    cpu: "1000m"
```

| 配置 | 作用 |
|------|------|
| requests | 调度时认为 Pod 至少需要多少资源 |
| limits | 容器最多可使用多少资源 |

CPU：

- `250m` = 0.25 个 CPU；
- `1000m` = 1 个 CPU；
- 超过 CPU limit 通常被节流。

内存：

- `512Mi` 是二进制单位；
- 超过 memory limit 可能 OOMKilled。

查看：

```bash
kubectl top pods -n iot-learn
kubectl describe pod -n iot-learn <pod-name>
```

## 20. 先认识但暂不深入的对象

| 对象 | 用途 | 与当前主线关系 |
|------|------|----------------|
| StatefulSet | 有稳定身份 / 顺序 / 持久化的有状态应用 | 数据库进 K8s 时再深入 |
| DaemonSet | 每节点运行一个 Pod | 日志、网络、监控 agent |
| Job | 运行到成功结束的任务 | 数据迁移、一次性处理 |
| CronJob | 按计划创建 Job | 定时清理、报表 |
| PVC / PV | 申请与提供持久存储 | 当前中间件留 Docker，暂不主讲 |
| HPA | 按指标自动扩缩副本 | 需要 metrics 和容量设计 |
| NetworkPolicy | 控制 Pod 间网络访问 | 生产安全需要 |
| ServiceAccount / RBAC | 身份与权限控制 | 生产必须补齐 |

---

# 第五部分：如何读 Kubernetes YAML

## 21. 四个最常见顶层字段

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: device-report-service
  namespace: iot-learn
spec:
  replicas: 1
```

| 字段 | 含义 |
|------|------|
| `apiVersion` | 这个对象使用哪个 API 组和版本 |
| `kind` | 对象类型 |
| `metadata` | 名称、Namespace、Label、Annotation 等身份信息 |
| `spec` | 用户声明的期望状态 |

运行后还会看到 `status`：

```bash
kubectl get deployment device-report-service \
  -n iot-learn -o yaml
```

`status` 通常由控制器写入，不应复制进普通声明文件。

## 22. YAML 基本语法

### 缩进

YAML 用空格表达层级，不能使用 Tab。

```yaml
spec:
  replicas: 1
```

### 列表

```yaml
containers:
  - name: device-report-service
    image: device-report-service:0.1.0-SNAPSHOT
```

### 字符串、数字、布尔值

对端口、内存和可能产生类型歧义的环境变量，按目标 API 要求使用类型。ConfigMap `data` 的值应是字符串：

```yaml
data:
  DB_PORT: "5432"
  FEATURE_ENABLED: "false"
```

### 多文档

一份文件可用 `---` 分隔多个对象：

```yaml
apiVersion: v1
kind: ConfigMap
# metadata / data 省略
---
apiVersion: apps/v1
kind: Deployment
# metadata / spec 省略
```

## 23. 声明式、幂等与调和

```bash
kubectl apply -f deployment.yaml
kubectl apply -f deployment.yaml
```

第二次 apply 相同内容通常不会重复创建 Deployment，而是确认期望状态没有变化。这就是声明式操作的幂等特征。

常用组合：

```bash
# 先看将发生什么
kubectl diff -f iot-learn-lab/infra/k8s/device-report/deployment.yaml

# 提交期望状态
kubectl apply -f iot-learn-lab/infra/k8s/device-report/deployment.yaml

# 删除该文件声明的对象
kubectl delete -f iot-learn-lab/infra/k8s/device-report/deployment.yaml
```

`delete -f` 是破坏性操作；先确认 context 和 Namespace。

不知道字段怎么写时，不必靠记忆猜：

```bash
kubectl api-resources
kubectl explain deployment
kubectl explain deployment.spec
kubectl explain deployment.spec.template.spec.containers
kubectl explain service.spec.ports
```

`kubectl explain` 读取当前集群支持的 API schema，比搜索一篇可能过时的示例更可靠。

---

# 第六部分：四类容易混淆的“配置文件”

## 24. minikube 启动配置

作用对象：**本地集群本身**。

```bash
minikube start --driver=docker --cpus=4 --memory=6144
minikube config set driver docker
```

它决定驱动、CPU、内存、Kubernetes 版本等，不负责创建业务 Deployment。

## 25. kubeconfig

作用对象：**客户端连接信息**。

```bash
kubectl config view --minify
kubectl config current-context
```

它告诉 kubectl / Helm：

- API Server 在哪里；
- 使用哪个身份；
- 当前 context 和 Namespace 是什么。

kubeconfig 可能包含凭据，不应随意提交 Git。

## 26. Kubernetes manifest

作用对象：**集群内 API 资源**。

```text
infra/k8s/
├── namespace.yaml
├── device-report/deployment.yaml
├── device-report/service.yaml
├── device-report/configmap-env.yaml
└── device-report/ingress.yaml
```

它声明 Deployment、Service 等期望状态，通常应该进入 Git。

## 27. Helm Values

作用对象：**Helm 模板输入**。

```yaml
deviceReport:
  replicaCount: 1
  image: device-report-service:0.1.0-SNAPSHOT
```

Values 本身不是 Kubernetes 对象。必须经过模板渲染：

```bash
helm template iot-learn \
  iot-learn-lab/infra/helm/iot-learn-lab \
  -f iot-learn-lab/infra/helm/iot-learn-lab/values.yaml
```

## 28. Spring `application-k8s.yml`

这是第五类配置，但它属于 **Java 应用**，不是 Kubernetes 配置：

```yaml
spring:
  datasource:
    url: jdbc:postgresql://${DB_HOST:host.minikube.internal}:${DB_PORT:5432}/iot_learn
```

配置链：

```text
Helm Values
 → Helm ConfigMap Template
 → Kubernetes ConfigMap
 → Pod 环境变量
 → Spring application-k8s.yml 占位符
 → Java 应用属性
```

### 配置对照

| 配置 | 谁读取 | 何时生效 | 通常进 Git |
|------|--------|----------|-------------|
| minikube flags/config | minikube | 集群创建 / 重启 | 项目命令可进文档；个人配置不进 |
| kubeconfig | kubectl / Helm | 连接集群时 | 否 |
| manifest | API Server / 控制器 | apply 后 | 是 |
| Helm Values | Helm | render / install / upgrade 时 | 非敏感值可进 |
| Spring application.yml | Spring Boot | 应用启动时 | 是 |

---

# 第七部分：使用裸 manifest 部署当前项目

## 29. 构建 Java 与镜像

```bash
cd iot-learn-lab
mvn -B clean verify

docker build \
  -f device-report-service/Dockerfile \
  -t device-report-service:0.1.0-SNAPSHOT \
  .
```

当前 Docker 与 minikube 节点的镜像存储不是同一个视角。构建后需要载入：

```bash
minikube image load device-report-service:0.1.0-SNAPSHOT
minikube image load command-dispatch-service:0.1.0-SNAPSHOT
minikube image load device-report-consumer:0.1.0-SNAPSHOT

minikube image ls | grep -E 'device-report|command-dispatch'
```

同 tag 重新构建时，`imagePullPolicy: IfNotPresent` 可能继续使用旧镜像。学习环境可先删除节点旧镜像再 load，或使用新的不可变 tag。

生产建议每次构建使用唯一 tag（如 Git SHA），不要覆盖同一个 tag。

## 30. 部署顺序

从仓库根目录：

```bash
kubectl apply -f iot-learn-lab/infra/k8s/namespace.yaml

kubectl apply -f iot-learn-lab/infra/k8s/device-report/configmap-env.yaml
kubectl apply -f iot-learn-lab/infra/k8s/command-dispatch/configmap-env.yaml
kubectl apply -f iot-learn-lab/infra/k8s/device-report-consumer/configmap-env.yaml

kubectl apply -f iot-learn-lab/infra/k8s/device-report/deployment.yaml
kubectl apply -f iot-learn-lab/infra/k8s/command-dispatch/deployment.yaml
kubectl apply -f iot-learn-lab/infra/k8s/device-report-consumer/deployment.yaml

kubectl apply -f iot-learn-lab/infra/k8s/device-report/service.yaml
kubectl apply -f iot-learn-lab/infra/k8s/command-dispatch/service.yaml
kubectl apply -f iot-learn-lab/infra/k8s/device-report-consumer/service.yaml

kubectl apply -f iot-learn-lab/infra/k8s/device-report/ingress.yaml
```

Kubernetes 不强制所有对象按这个顺序创建，但按依赖顺序更容易理解和排错。

## 31. 验证部署

```bash
kubectl get all -n iot-learn
kubectl get configmap,ingress -n iot-learn

kubectl rollout status deployment/device-report-service \
  -n iot-learn --timeout=180s
kubectl rollout status deployment/command-dispatch-service \
  -n iot-learn --timeout=180s
kubectl rollout status deployment/device-report-consumer \
  -n iot-learn --timeout=180s
```

临时本地访问：

```bash
kubectl port-forward \
  -n iot-learn \
  svc/device-report-service \
  8765:8765
```

另一个终端：

```bash
curl http://127.0.0.1:8765/actuator/health
```

集群内 DNS 验证：

```bash
kubectl exec -n iot-learn deploy/device-report-service -- \
  wget -qO- http://command-dispatch-service:8767/actuator/health
```

## 32. 混合部署网络边界

“localhost”总是相对于当前网络空间：

| 命令在哪里运行 | `localhost` 指谁 |
|----------------|------------------|
| WSL 终端 | WSL 自己 |
| Docker 容器 | 当前容器 |
| minikube Pod | 当前 Pod |
| Windows 浏览器 | Windows |

当前项目约定：

| 地址 | 用途 |
|------|------|
| `host.minikube.internal` | Pod 访问 minikube 宿主机上的 DB / Redis / Kafka |
| `192.168.19.64`（以实测为准） | WSL 对 Windows / Pod 可达地址；Nacos 等可能需要 |
| `command-dispatch-service:8767` | Pod 内通过 K8s Service DNS 调 dispatch |

不要把示例 IP 当成所有机器都固定的地址。重启 WSL 或更换网络后先检查：

```bash
hostname -I
ip -4 addr show eth0
ip -4 route show default
```

改 IP 时要同时检查 ConfigMap、Helm Values、Kafka `advertised.listeners` 和 Prometheus scrape target；只改其中一处可能表现为“端口通，但客户端仍连接旧地址”。

Kafka 尤其要区分 bootstrap 与 advertised listener：端口能连通，不代表 broker 返回的地址对 Pod 可达。

---

# 第八部分：Helm 入门

## 33. Chart、Values、Template、Release、Revision

### Chart

一套可安装的 Kubernetes 包：

```text
iot-learn-lab/infra/helm/iot-learn-lab/
├── Chart.yaml
├── values.yaml
├── values-v1.yaml
├── values-v2.yaml
├── .helmignore
└── templates/
```

### Values

模板参数。当前项目集中保存镜像、副本、端口、中间件地址等。

### Template

带 Go Template 表达式的 Kubernetes YAML：

```yaml
replicas: {{ .Values.deviceReport.replicaCount }}
```

### Release

Chart 在某个 Namespace 中的一次命名安装实例。

```text
Chart：iot-learn-lab
Release：iot-learn
Namespace：iot-learn
```

同一个 Chart 可以用不同 Release 名安装多次。

### Revision

Release 的历史版本号。每次 install / upgrade / rollback 都会产生新的 revision。

```bash
helm history iot-learn -n iot-learn
```

## 34. Chart.yaml

当前项目：

```yaml
apiVersion: v2
name: iot-learn-lab
description: Stage 2 Helm chart for iot-learn-lab (hybrid middleware)
type: application
version: 0.1.0
appVersion: "0.1.0-SNAPSHOT"
```

字段：

| 字段 | 含义 |
|------|------|
| `apiVersion: v2` | Helm 3 Chart API |
| `name` | Chart 名 |
| `description` | 描述 |
| `type: application` | 可部署应用 Chart |
| `version` | Chart 自身版本；模板 / Chart 变化时更新 |
| `appVersion` | 应用版本说明；不会自动改镜像 tag |

## 35. values.yaml 逐项解释

### Namespace 与全局值

```yaml
namespace: iot-learn

global:
  imagePullPolicy: IfNotPresent
  springProfilesActive: k8s
```

- `namespace`：模板把对象渲染到哪个 Namespace；
- `imagePullPolicy`：节点已有镜像时不重复拉；
- `springProfilesActive`：最终进入 ConfigMap，激活 Spring `k8s` profile。

注意：更通用的 Chart 往往使用 `.Release.Namespace`，而不是在 Values 再定义 Namespace。当前项目保留 `namespace` 是学习阶段的显式做法，命令的 `-n iot-learn` 与该值必须一致。

### 中间件

```yaml
middleware:
  dbHost: host.minikube.internal
  dbPort: "5432"
  redisHost: host.minikube.internal
  redisPort: "6379"
  nacosAddr: "192.168.19.64:8848"
  kafkaBootstrap: host.minikube.internal:9092
```

这些值不会被 Java 直接读取，而是先渲染到 ConfigMap。

### device-report

```yaml
deviceReport:
  enabled: true
  name: device-report-service
  replicaCount: 1
  image: device-report-service:0.1.0-SNAPSHOT
  versionLabel: v1
  port: 8765
  nodePort: 30765
  dispatchBaseUrl: http://command-dispatch-service:8767
```

| 字段 | 含义 |
|------|------|
| `enabled` | 条件渲染开关 |
| `name` | Deployment / Service 名 |
| `replicaCount` | Pod 副本期望数 |
| `image` | 容器镜像 |
| `versionLabel` | Pod 的版本标签，不会自动切换镜像 |
| `port` | Service 与容器应用端口 |
| `nodePort` | 节点对外端口 |
| `dispatchBaseUrl` | ConfigMap 注入的 Feign 地址 |

### resources

```yaml
resources:
  requests:
    memory: 512Mi
    cpu: 250m
  limits:
    memory: 1Gi
    cpu: "1000m"
```

模板使用 `toYaml` 整段输出，避免逐字段复制。

### Ingress

```yaml
ingress:
  enabled: true
  className: nginx
  host: device-report.iot-learn.local
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: "2m"
```

这些值最终生成 Ingress 的 class、Host 和 Annotation。

## 36. Values 覆盖顺序

当前项目：

```bash
helm template iot-learn CHART \
  -f CHART/values.yaml \
  -f CHART/values-v2.yaml \
  --set deviceReport.replicaCount=2
```

从低到高：

```text
Chart 内 values.yaml
  < 左侧 -f 文件
  < 右侧 -f 文件
  < --set
```

右侧覆盖左侧；未覆盖的键继续继承。

建议：

- 长期、可审查配置写 Values 文件；
- 临时实验用 `--set`；
- 不要把复杂结构长期堆在 `--set`；
- 敏感值不要明文提交。

## 37. 常见模板语法

### `.Values`

```yaml
replicas: {{ .Values.deviceReport.replicaCount }}
```

读取 Values。

### `.Release`

```yaml
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
```

读取当前 Release 信息。

### 条件

```gotemplate
{{- if .Values.deviceReport.enabled }}
# 这里放要条件渲染的 Kubernetes YAML
{{- end }}
```

值为 false 时不生成该资源。

### `quote`

```yaml
image: {{ .Values.deviceReport.image | quote }}
```

把值输出为带引号字符串，减少 YAML 类型歧义。

### `toYaml` 与 `nindent`

```gotemplate
resources:
  {{- toYaml .Values.deviceReport.resources | nindent 12 }}
```

- `toYaml`：把 map 转成 YAML；
- `nindent 12`：换行后缩进 12 个空格。

缩进错误是 Helm 模板常见故障。

### `include`

```gotemplate
{{- include "iot-learn-lab.labels" . | nindent 4 }}
```

调用 `templates/helpers.tpl` 中定义的可复用模板。

当前仓库文件名是 `templates/helpers.tpl`。Helm 会处理 `templates/` 中的模板；社区更常见命名是 `_helpers.tpl`，以下划线强调它不是独立 Kubernetes 对象。

## 38. Helm 的渲染和部署边界

```bash
CHART="iot-learn-lab/infra/helm/iot-learn-lab"
helm lint "$CHART"
```

检查 Chart 结构和部分模板问题，不写集群。

```bash
helm template iot-learn "$CHART" -f "$CHART/values.yaml"
```

本地渲染，不写集群。适合学习和检查最终 YAML。

```bash
helm upgrade --install iot-learn "$CHART" \
  -n iot-learn \
  -f "$CHART/values.yaml" \
  --wait
```

渲染后写集群，并维护 Release。

即使 Helm 命令成功，业务也可能不通，例如：

- 镜像不存在；
- Pod CrashLoop；
- readiness 不通过；
- Service selector 错；
- 中间件不可达。

Helm 管 Release，不代替 `kubectl logs` 和对象排障。

---

# 第九部分：使用 Helm 部署当前项目

## 39. 部署前检查

```bash
kubectl config current-context
kubectl get nodes
helm version

CHART="iot-learn-lab/infra/helm/iot-learn-lab"
helm lint "$CHART"
helm template iot-learn "$CHART" \
  -n iot-learn \
  -f "$CHART/values.yaml" \
  -f "$CHART/values-v1.yaml" > /tmp/iot-learn-rendered.yaml
```

检查渲染结果：

```bash
grep -nE '^kind:|^  name:|image:|replicas:' \
  /tmp/iot-learn-rendered.yaml
```

## 40. 裸 manifest 与 Helm 资源归属

如果同名 Deployment 已由 `kubectl apply` 创建，Helm 安装时可能因缺少 Helm ownership metadata 而拒绝接管。

不要同时用裸 manifest 和 Helm 管理同一批对象。

学习环境迁移方式：

1. 确认 YAML / Values 都在 Git；
2. 删除旧的业务对象；
3. 用 Helm 重新创建；
4. 保留 Namespace 和本地镜像；
5. 验证业务。

执行删除前先检查：

```bash
kubectl get all,configmap,ingress -n iot-learn
```

不要在不理解影响时复制批量删除命令。

## 41. 安装或升级

```bash
CHART="iot-learn-lab/infra/helm/iot-learn-lab"

helm upgrade --install iot-learn "$CHART" \
  -n iot-learn \
  --create-namespace \
  -f "$CHART/values.yaml" \
  -f "$CHART/values-v1.yaml" \
  --wait \
  --timeout 5m
```

参数：

| 参数 | 含义 |
|------|------|
| `upgrade --install` | 有 Release 就升级，没有就安装 |
| `iot-learn` | Release 名 |
| `"$CHART"` | Chart 路径 |
| `-n iot-learn` | Release 所在 Namespace |
| `--create-namespace` | Namespace 不存在时创建 |
| `-f` | Values 覆盖文件 |
| `--wait` | 等关键资源 Ready 后再返回成功 |
| `--timeout 5m` | 最长等待时间 |

当前 Chart 没有单独渲染 `Namespace` 对象，因此必须满足以下任一条件：

1. 命令带 `--create-namespace`；或
2. 预先执行 `kubectl apply -f iot-learn-lab/infra/k8s/namespace.yaml`。

`values.yaml` 的 `namespace: iot-learn` 与命令的 `-n iot-learn` 必须保持一致。

安装完成后才运行：

```bash
iot-learn-lab/scripts/stage2/scenario-k4-helm-baseline.sh
```

K4 脚本用于验证已有 Release，不负责替你执行首次 `helm install`。

## 42. 查看 Release

```bash
helm list -n iot-learn
helm status iot-learn -n iot-learn
helm get values iot-learn -n iot-learn
helm get values iot-learn -n iot-learn --all
helm get manifest iot-learn -n iot-learn
helm history iot-learn -n iot-learn
```

区别：

- `get values`：查看用户覆盖值；
- `get values --all`：连默认计算值一起看；
- `get manifest`：查看该 revision 最终提交的 Kubernetes YAML；
- `history`：查看 revision 历史。

## 43. 升级副本或 Values

临时实验：

```bash
helm upgrade iot-learn "$CHART" \
  -n iot-learn \
  -f "$CHART/values.yaml" \
  -f "$CHART/values-v1.yaml" \
  --set deviceReport.replicaCount=2 \
  --wait

kubectl get pods -n iot-learn -l app=device-report-service
```

持久修改应写入 Values 文件再升级，避免命令历史成为唯一配置来源。

## 44. 回滚

```bash
helm history iot-learn -n iot-learn
helm rollback iot-learn 1 -n iot-learn --wait
```

回滚会把 Release 恢复到目标 revision 的 Chart / Values / manifest 状态，并产生一个新的 revision。

注意：

- Helm 回滚 Kubernetes 资源，不回滚 PostgreSQL 数据；
- 不自动修复不兼容数据库迁移；
- 不保证外部中间件状态恢复；
- `helm uninstall` 后默认不能再普通 rollback，除非采用保留历史策略且理解其语义。

## 45. 卸载

```bash
helm uninstall iot-learn -n iot-learn
```

它会删除 Release 管理的资源并删除默认 Release 历史。执行前先看：

```bash
helm status iot-learn -n iot-learn
helm get manifest iot-learn -n iot-learn
```

---

# 第十部分：常用命令（按问题分类）

## 46. 集群与 context

```bash
minikube status
minikube ip
minikube profile list
kubectl cluster-info
kubectl config get-contexts
kubectl config current-context
kubectl get nodes -o wide
```

## 47. 查看资源

```bash
kubectl get all -n iot-learn
kubectl get pods -n iot-learn -o wide
kubectl get pods -n iot-learn --show-labels
kubectl get deploy,rs,pod -n iot-learn
kubectl get svc,endpoints,endpointslices -n iot-learn
kubectl get ingress,configmap -n iot-learn
kubectl describe pod -n iot-learn <pod-name>
kubectl get deployment device-report-service -n iot-learn -o yaml
```

## 48. 创建、更新、比较与删除

```bash
kubectl diff -f <file-or-directory>
kubectl apply -f <file-or-directory>
kubectl delete -f <file-or-directory>

kubectl scale deployment/device-report-service \
  -n iot-learn --replicas=2

kubectl rollout restart deployment/device-report-service \
  -n iot-learn
```

`scale` / `rollout restart` 适合操作；若 Git 中 manifest / Values 仍写旧值，后续 apply / upgrade 可能覆盖手工操作。

## 49. 日志、事件与容器调试

```bash
kubectl logs -n iot-learn deploy/device-report-service
kubectl logs -n iot-learn deploy/device-report-service -f
kubectl logs -n iot-learn <pod-name> --previous
kubectl logs -n iot-learn <pod-name> -c <container-name>

kubectl get events -n iot-learn \
  --sort-by=.metadata.creationTimestamp

kubectl exec -it -n iot-learn <pod-name> -- sh
```

`--previous` 对 CrashLoopBackOff 很重要，它查看上一次崩溃容器日志。

## 50. 网络、DNS 与端口

```bash
kubectl get svc,endpoints -n iot-learn

kubectl port-forward -n iot-learn \
  svc/device-report-service 8765:8765

kubectl exec -n iot-learn deploy/device-report-service -- \
  wget -qO- http://command-dispatch-service:8767/actuator/health

curl -H "Host: device-report.iot-learn.local" \
  "http://$(minikube ip)/actuator/health"
```

## 51. 镜像与 rollout

```bash
minikube image ls
minikube image load device-report-service:0.1.0-SNAPSHOT

kubectl get deployment/device-report-service \
  -n iot-learn \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'

kubectl rollout status deployment/device-report-service -n iot-learn
kubectl rollout history deployment/device-report-service -n iot-learn
kubectl rollout undo deployment/device-report-service -n iot-learn
```

## 52. Helm 渲染、Release 与回滚

```bash
helm lint "$CHART"
helm template iot-learn "$CHART" -f "$CHART/values.yaml"
helm upgrade --install iot-learn "$CHART" -n iot-learn --wait
helm list -n iot-learn
helm status iot-learn -n iot-learn
helm get values iot-learn -n iot-learn --all
helm get manifest iot-learn -n iot-learn
helm history iot-learn -n iot-learn
helm rollback iot-learn <revision> -n iot-learn --wait
helm uninstall iot-learn -n iot-learn
```

## 53. 命令风险分级

| 级别 | 示例 | 说明 |
|------|------|------|
| 只读 | `get`、`describe`、`logs`、`helm status` | 优先用于排障 |
| 可逆修改 | `apply`、`upgrade`、`scale`、`rollout restart` | 确认 context / ns |
| 删除性 | `kubectl delete`、`helm uninstall` | 先查看对象和备份配置 |
| 高风险 | `minikube delete --all`、批量删除 Namespace | 会丢失本地集群状态 |

---

# 第十一部分：故障树

## 54. 固定排障顺序

遇到“服务不通”，不要立刻重启所有东西。按层次定位：

```text
1. kubectl 是否连对集群？
2. 声明对象是否存在、配置是否正确？
3. Pod 是否成功启动？
4. readiness 是否通过？
5. Service 是否选中 Endpoint？
6. Ingress Host / Path 是否匹配？
7. Pod 到外部中间件是否可达？
8. Helm 渲染值是否就是你以为的值？
```

## 55. kubectl 尝试连接 localhost:8080

可能原因：

- minikube 未启动；
- kubeconfig 不存在或错误；
- 当前 context 错。

```bash
minikube status
minikube start
kubectl config get-contexts
kubectl config use-context minikube
kubectl cluster-info
```

## 56. ImagePullBackOff / ErrImagePull

可能原因：

- 本地镜像未 load；
- tag 写错；
- `imagePullPolicy: Always` 强制去远端拉；
- 私有仓库无凭据。

```bash
kubectl describe pod -n iot-learn <pod-name>
minikube image ls | grep device-report
kubectl get deployment device-report-service \
  -n iot-learn -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

## 57. CrashLoopBackOff

含义：容器启动后不断退出，Kubernetes 退避重启。

```bash
kubectl logs -n iot-learn <pod-name> --previous
kubectl describe pod -n iot-learn <pod-name>
```

Java 常见原因：

- DB / Kafka / Nacos 地址不可达；
- 环境变量缺失；
- profile 错；
- 内存不足 / OOMKilled；
- 配置语法错误。

## 58. Pod Running 但 NotReady

Running 只说明容器进程在运行，不代表 readiness 成功。

```bash
kubectl get pods -n iot-learn
kubectl describe pod -n iot-learn <pod-name>
kubectl logs -n iot-learn <pod-name>
```

检查：

- `/actuator/health/readiness` 是否存在；
- 探针端口是否与应用端口一致；
- initial delay 是否过短；
- 应用健康是否依赖未就绪中间件。

## 59. Service 存在但访问失败

```bash
kubectl get svc device-report-service -n iot-learn
kubectl get endpoints device-report-service -n iot-learn
kubectl get pods -n iot-learn --show-labels
```

若 Endpoints 为空，重点比较：

```text
Service spec.selector
        vs
Pod metadata.labels
```

还要检查 Pod 是否 Ready，以及 `targetPort` 是否正确。

## 60. Ingress 返回 404

```bash
kubectl get ingress -n iot-learn
kubectl describe ingress device-report-ingress -n iot-learn
kubectl get pods -n ingress-nginx
```

检查：

- ingress addon / controller 是否运行；
- 请求 Host 是否为 `device-report.iot-learn.local`；
- path / pathType 是否匹配；
- backend Service 和 port 是否存在；
- Service 是否有 Endpoints。

## 61. ConfigMap 已更新，应用仍读旧值

`envFrom` 在容器创建时注入环境变量，不会热更新。

```bash
kubectl get configmap device-report-middleware \
  -n iot-learn -o yaml

kubectl rollout restart deployment/device-report-service \
  -n iot-learn

kubectl rollout status deployment/device-report-service \
  -n iot-learn
```

## 62. Helm lint / template 失败

```bash
helm lint "$CHART"
helm template iot-learn "$CHART" \
  -f "$CHART/values.yaml" \
  --debug
```

常见原因：

- `{{ if }}` / `{{ end }}` 不配对；
- `toYaml` 后缩进不正确；
- Values 路径拼错；
- YAML 类型或冒号引号问题；
- helpers 不在 templates 范围或 define 名不一致。

## 63. Helm Release deployed，但业务不通

先分别看 Helm 和 Kubernetes：

```bash
helm status iot-learn -n iot-learn
helm get manifest iot-learn -n iot-learn
helm get values iot-learn -n iot-learn --all

kubectl get pods,svc,endpoints,ingress -n iot-learn
kubectl get events -n iot-learn \
  --sort-by=.metadata.creationTimestamp
```

Helm 的 deployed 表示 Release 操作完成；未使用 `--wait` 时尤其不代表业务健康。

## 64. 裸 manifest 与 Helm 归属冲突

现象通常包含：

- resource already exists；
- invalid ownership metadata；
- 缺少 `app.kubernetes.io/managed-by=Helm`；
- 缺少 `meta.helm.sh/release-*` annotation。

处理原则：

1. 决定唯一管理者；
2. 学习环境优先删除旧裸资源，再由 Helm 重建；
3. 不要不理解元数据语义就手工伪造 Helm ownership；
4. `infra/k8s` 保留作教材和排障对照，不再与 Helm 并行管理同名对象。

---

# 第十二部分：练习与自测

## 65. 练习一：修改副本

目标：理解 Deployment、ReplicaSet、Pod 的关系。

```bash
kubectl scale deployment/device-report-service \
  -n iot-learn --replicas=2

kubectl get deploy,rs,pod -n iot-learn \
  -l app=device-report-service
```

观察：

- Deployment desired / ready；
- ReplicaSet 副本；
- 两个 Pod 的名字和 IP。

若当前由 Helm 管理，完成观察后用 Values + `helm upgrade` 恢复，避免下次升级覆盖产生困惑。

## 66. 练习二：故意打错 Service selector

仅在本地学习集群执行，并先保存原配置。

1. 把 Service selector 临时改成不存在的 label；
2. apply；
3. 观察 Endpoints 为空；
4. 恢复 selector；
5. 再观察 Endpoints。

核心命令：

```bash
kubectl get pods -n iot-learn --show-labels
kubectl get endpoints device-report-service -n iot-learn
kubectl describe svc device-report-service -n iot-learn
```

## 67. 练习三：修改 ConfigMap

目标：证明 envFrom 不会更新现有容器环境变量。

1. 修改一个无风险配置；
2. apply ConfigMap；
3. 不重启 Pod，观察旧值；
4. rollout restart；
5. 观察新 Pod 读取新值。

## 68. 练习四：Helm 渲染，不部署

```bash
CHART="iot-learn-lab/infra/helm/iot-learn-lab"

helm template iot-learn "$CHART" \
  -f "$CHART/values.yaml" \
  --set deviceReport.replicaCount=3 \
  | grep -n -A3 '^kind: Deployment'
```

回答：

- 为什么集群副本没有变化？
- 哪一步才会把 YAML 写入 API Server？

## 69. 练习五：upgrade / history / rollback

```bash
helm upgrade iot-learn "$CHART" \
  -n iot-learn \
  -f "$CHART/values.yaml" \
  --set deviceReport.replicaCount=2 \
  --wait

helm history iot-learn -n iot-learn

helm rollback iot-learn <previous-revision> \
  -n iot-learn --wait
```

观察 rollback 后 revision 继续增加，而不是“把历史编号倒退”。

## 70. 自测题

1. Docker、minikube、Kubernetes、kubectl、Helm 各自负责什么？
2. API Server、etcd、Scheduler、Controller Manager 的职责是什么？
3. Scheduler 和 kubelet 的分工是什么？
4. 为什么删掉 Deployment 管理的 Pod 后它会回来？
5. Pod Running 为什么仍可能无法接收 Service 流量？
6. Deployment selector、Pod label、Service selector 如何连接？
7. `port`、`targetPort`、`nodePort` 分别在哪一层？
8. Ingress 和 Ingress Controller 有何区别？
9. ConfigMap 更新后，为何 Pod 环境变量没有自动改变？
10. requests 和 limits 分别影响什么？
11. minikube 配置、kubeconfig、manifest、Values 有何区别？
12. Chart、Release、Revision 是什么？
13. `values.yaml` 与 Spring `application.yml` 有何区别？
14. 多个 `-f` 与 `--set` 的覆盖顺序是什么？
15. Helm Release 显示 deployed，为什么业务仍可能失败？
16. Service Endpoints 为空时，你首先比较哪两个字段？
17. CrashLoopBackOff 最重要的两条查看命令是什么？
18. 为什么本地 Docker build 后还要 `minikube image load`？

---

# 第十三部分：学习边界

## 71. 当前必须掌握

- Pod / Deployment / ReplicaSet 的关系；
- Label / Selector；
- Service / Ingress；
- ConfigMap 与 Spring 配置映射；
- readiness / liveness；
- requests / limits；
- kubectl 查看、apply、logs、rollout；
- Chart / Values / Template / Release / Revision；
- Helm lint、template、upgrade、history、rollback；
- 按对象链路排障。

## 72. 暂时理解定位即可

- StatefulSet、DaemonSet、Job、CronJob；
- PV / PVC / StorageClass；
- HPA；
- NetworkPolicy；
- RBAC；
- 多节点调度高级策略；
- Helm dependency / subchart。

## 73. 上生产前必须继续补齐

- 多控制面高可用与集群升级；
- 镜像仓库、签名、漏洞扫描与唯一 tag；
- Secret 外部管理与 etcd 加密；
- RBAC 最小权限与审计；
- NetworkPolicy 与入口 TLS；
- 容量规划、LimitRange、ResourceQuota；
- Stateful workload 备份恢复；
- PodDisruptionBudget、反亲和性、拓扑分布；
- 日志、Metrics、Trace 与告警；
- GitOps、发布审批与回滚策略；
- 数据库 schema 变更与应用回滚兼容性。

minikube 上“能跑”只是第一步，不等于具备生产可靠性。

---

# 附录：当前项目文件导航

| 路径 | 作用 |
|------|------|
| `iot-learn-lab/infra/k8s/namespace.yaml` | Namespace |
| `iot-learn-lab/infra/k8s/*/configmap-env.yaml` | 裸 ConfigMap |
| `iot-learn-lab/infra/k8s/*/deployment.yaml` | 裸 Deployment |
| `iot-learn-lab/infra/k8s/*/service.yaml` | 裸 Service |
| `iot-learn-lab/infra/k8s/device-report/ingress.yaml` | 裸 Ingress |
| `iot-learn-lab/infra/helm/iot-learn-lab/Chart.yaml` | Chart 元数据 |
| `iot-learn-lab/infra/helm/iot-learn-lab/values.yaml` | 默认部署参数 |
| `iot-learn-lab/infra/helm/iot-learn-lab/values-v1.yaml` | v1 覆盖 |
| `iot-learn-lab/infra/helm/iot-learn-lab/values-v2.yaml` | v2 覆盖 |
| `iot-learn-lab/infra/helm/iot-learn-lab/templates/` | Kubernetes 模板 |
| `iot-learn-lab/scripts/stage2/` | K1–K4 场景验证脚本 |

已有分周材料仍可作为实验补充：

- W1：`2026-07-14-stage2-w1-k8s-primer.md`
- W2：`2026-07-16-stage2-w2-service-dns-kafka.md`
- W3：`2026-07-16-stage2-w3-ingress-prometheus.md`
- W4：`2026-07-17-stage2-w4-helm-primer.md`

本手册提供完整心智模型；分周指南提供更具体的当周执行上下文。

当前仓库进度以 Stage 2 W4 为止：minikube、三服务、Ingress、外部 Prometheus 与 Helm Chart 已有对应材料；Argo CD、Argo Rollouts、Jaeger、GitHub Actions 属于 W6–W10 后续阶段，不应理解为本手册已经部署的组件。

---

# 官方资料

- Kubernetes Overview：https://kubernetes.io/docs/concepts/overview/
- Kubernetes Components：https://kubernetes.io/docs/concepts/overview/components/
- Kubernetes API Concepts：https://kubernetes.io/docs/reference/using-api/
- kubectl Quick Reference：https://kubernetes.io/docs/reference/kubectl/quick-reference/
- minikube Start：https://minikube.sigs.k8s.io/docs/start/
- minikube Docker Driver：https://minikube.sigs.k8s.io/docs/drivers/docker/
- Helm Using Helm：https://helm.sh/docs/intro/using_helm/
- Helm Charts：https://helm.sh/docs/topics/charts/
- Helm Template Guide：https://helm.sh/docs/chart_template_guide/
