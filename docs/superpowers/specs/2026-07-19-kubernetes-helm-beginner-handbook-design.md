# Kubernetes 与 Helm 零基础手册设计

**日期：** 2026-07-19  
**状态：** 已确认，待编写  
**目标读者：** 有约四年 Java 开发经验，但没有 Kubernetes、kubectl、minikube、Helm 使用经验的开发人员

## 背景

仓库已有 W1–W4 分周指南，分别覆盖 Kubernetes 首次部署、Service DNS、Ingress、Prometheus 与 Helm Chart。现有内容适合跟随 Stage 2 周计划逐周阅读，但知识分散，且部分章节默认读者已经完成前序实验。

本次新增一份可独立阅读的完整手册。读者不需要先打开 W1–W4 文档，但所有示例都采用当前 `iot-learn-lab` 的三服务、混合中间件与 minikube 环境，避免另造一套脱离项目的示例。

## 学习目标

读完并完成练习后，读者应能：

1. 区分 Docker、minikube、Kubernetes、kubectl 与 Helm 的职责。
2. 说明 Kubernetes 集群控制面与工作节点的基本组件及请求流。
3. 在 WSL2 Docker 环境中创建、验证、停止和重建 minikube 集群。
4. 读懂 Namespace、Deployment、Pod、Service、Ingress、ConfigMap、Secret 等基本对象。
5. 读懂 Kubernetes YAML 的 `apiVersion`、`kind`、`metadata`、`spec` 与运行时 `status`。
6. 解释标签、选择器、探针、资源 requests/limits、端口和环境变量等项目配置。
7. 区分 minikube 启动配置、kubeconfig、Kubernetes manifest 和 Helm Values。
8. 使用裸 manifest 完成镜像加载、资源部署、查看、更新、回滚与排障。
9. 解释 Chart、Template、Values、Release 与 Revision，并用当前 Chart 安装、升级和回滚。
10. 根据现象选择正确的 kubectl、minikube 或 Helm 命令定位问题。

## 教学方法

采用“项目主线 + 渐进解释 + 章节速查”：

1. 先展示一个可运行的命令和预期结果。
2. 再解释该步骤引入的组件与字段。
3. 用当前仓库文件逐项映射概念。
4. 每一大章以命令速查、自测题或可观察结果收尾。
5. 明确区分“开发人员当前必须掌握”“暂时了解即可”“生产环境后续补齐”。

文档不采用先罗列全部术语的百科写法，也不只提供缺少心智模型的命令清单。

## 文档位置

新增：

`docs/superpowers/guides/2026-07-19-kubernetes-helm-beginner-handbook.md`

该文件独立完整；可以引用当前项目路径作为示例，但不要求读者先阅读其他 Stage 2 指南。

## 内容结构

### 1. 工具边界与整体链路

- Docker：构建和运行容器。
- minikube：在本机创建和管理学习用 Kubernetes 集群。
- Kubernetes：声明并调和工作负载。
- kubectl：访问 Kubernetes API 的客户端。
- Helm：把多份参数化 manifest 作为一个 Release 管理。
- 从 Java 源码到 HTTP 请求进入 Pod 的完整路径。

### 2. Kubernetes 集群组件

- Control Plane：API Server、etcd、Scheduler、Controller Manager。
- Node：kubelet、容器运行时、kube-proxy / Service 网络。
- CoreDNS 与 Ingress Controller 的位置。
- `kubectl apply` 后各组件如何协作。
- 单节点 minikube 与生产多节点集群的区别。

### 3. 从零搭建 minikube 集群

- WSL2 Docker 前置检查。
- 安装并验证 kubectl、minikube、Helm。
- `minikube start --driver=docker --cpus=4 --memory=6144` 的参数含义。
- kubeconfig context 的生成与检查。
- addons：metrics-server、ingress。
- 启动、暂停、停止、删除与重建的区别。
- 集群健康检查与预期输出。

### 4. Kubernetes 对象模型

- Namespace、Pod、ReplicaSet、Deployment。
- Service：ClusterIP、NodePort、LoadBalancer。
- Ingress 与 Ingress Controller。
- ConfigMap 与 Secret。
- Label、Selector、Annotation、Owner Reference。
- Job、CronJob、StatefulSet、DaemonSet、PVC 只做定位性介绍，避免扩张主线。

### 5. Kubernetes YAML 通用语法

- `apiVersion`、`kind`、`metadata`、`spec`。
- `status` 是控制器写入的运行状态，不应作为普通声明配置提交。
- YAML 缩进、列表、字符串、数字与布尔值。
- 声明式、幂等与 reconciliation。
- `kubectl apply -f`、`diff`、`delete -f` 的关系。

### 6. 当前项目 manifest 逐项拆解

以 `iot-learn-lab/infra/k8s/` 为例：

- Namespace 的用途。
- Deployment：replicas、selector、template、containers、image、ports、envFrom。
- readiness、liveness 与 startup probe 的职责边界。
- resources requests/limits 对调度与容器上限的影响。
- Service 的 port、targetPort、nodePort 与 selector。
- Ingress 的 className、host、path、pathType 与 backend。
- ConfigMap 到 Spring Boot 环境变量 / `application-k8s.yml` 的映射。
- 当前混合部署中的 `host.minikube.internal`、WSL IP 与 localhost 边界。

### 7. 四类“配置文件”

明确消除“配置集群”这一表述中的歧义：

1. minikube 启动参数或 profile：决定本地集群的驱动、CPU、内存和 Kubernetes 版本。
2. kubeconfig：决定 kubectl 连接哪个 API Server、使用哪个用户和 context。
3. Kubernetes manifest：声明集群内要存在的对象和期望状态。
4. Helm Values：作为模板输入，生成最终 Kubernetes manifest。

每类配置均包含示例、使用者、作用时机、是否进入 Git 与常见误用。

### 8. 裸 manifest 部署实战

- Maven 打包与 Docker 镜像。
- 本地 Docker 镜像和 minikube 节点镜像的区别。
- `minikube image load`。
- 按 Namespace → ConfigMap → Deployment → Service → Ingress 顺序部署。
- rollout 状态、端口转发、Service DNS、Ingress Host 访问。
- 修改 ConfigMap / 镜像后为什么需要重新创建 Pod。

### 9. Helm 心智模型

- Chart、Chart.yaml、templates、values、Release、Revision。
- Helm 渲染阶段与 Kubernetes 调和阶段的边界。
- `values.yaml` 不是 Spring `application.yml`。
- 单 Chart 多 Deployment 与子 Chart 的取舍。
- Go Template 中 `.Values`、`.Release`、`include`、`toYaml`、`nindent`、`quote`、条件块。

### 10. 当前项目 Chart 逐项拆解

以 `iot-learn-lab/infra/helm/iot-learn-lab/` 为例：

- Chart.yaml 元数据。
- values.yaml 中 global、middleware、三服务、resources、Ingress 的含义。
- values-v1 / values-v2 的覆盖顺序。
- ConfigMap、Deployment、Service、Ingress 模板如何读取 Values。
- helpers 模板和统一 labels。
- 从 Values 到渲染 YAML、再到集群对象和 Spring 环境变量的数据流。

### 11. Helm 实战

- `helm lint`、`helm template`、`helm upgrade --install`。
- `helm status`、`get values`、`get manifest`、`history`。
- 修改副本与镜像。
- rollback 的 revision 模型。
- uninstall 的影响。
- 从裸 manifest 迁移到 Helm 时的资源归属冲突。
- 持久配置写 Values，临时实验用 `--set`。

### 12. 常用命令速查

按问题分类，而不是按工具简单罗列：

- 集群与 context。
- 查看对象与状态。
- 创建、更新和删除。
- 日志、事件和容器调试。
- 网络、DNS、端口转发与 Ingress。
- 镜像和 rollout。
- Helm 渲染、发布、历史与回滚。
- 安全的只读命令与高风险删除命令。

### 13. 故障树

固定按“配置是否正确 → 对象是否存在 → Pod 是否启动 → 探针是否通过 → Service 是否有 Endpoints → 入口是否匹配”排查：

- kubectl 连 `localhost:8080`。
- ImagePullBackOff / ErrImagePull。
- CrashLoopBackOff。
- Pod Running 但 NotReady。
- Service 访问失败或 Endpoints 为空。
- Ingress 404。
- ConfigMap 已更新但应用仍读旧值。
- Helm template / lint 失败。
- Helm Release 成功但业务不通。
- 裸 manifest 与 Helm 资源归属冲突。

### 14. 学习边界

当前必须掌握：

- Deployment、Service、ConfigMap、Ingress、探针、资源、kubectl 基础、Helm Release 生命周期。

暂时了解：

- StatefulSet、DaemonSet、PVC、NetworkPolicy、RBAC、HPA。

生产前必须补齐：

- Secret 管理、RBAC、资源容量规划、多节点高可用、持久化、网络策略、镜像仓库、备份恢复、集群升级和安全基线。

### 15. 练习与自测

- 修改副本并观察 ReplicaSet / Pod。
- 故意打错 selector 并通过 Endpoints 定位。
- 修改 ConfigMap 后验证旧 Pod 与新 Pod 的差异。
- 用 Helm Values 切换副本和 version label。
- 完成一次 upgrade / history / rollback。
- 用故障现象选择最先执行的命令。

## 准确性与项目约束

1. 命令以当前 Windows + WSL2 Docker + minikube driver 环境为准。
2. 示例使用 `iot-learn` Namespace 和当前三服务端口。
3. 不把 PostgreSQL、Redis、Kafka、Nacos 迁入 Kubernetes；继续采用混合中间件架构。
4. 不修改当前未提交的 Helm Chart 实现；若手册发现实现问题，只在文档中说明正确规则，不趁机改代码。
5. 不把 ConfigMap 中的明文数据库密码描述成生产最佳实践；明确指出应使用 Secret 或外部密钥系统。
6. Kubernetes 与 Helm 易变化的安装命令和版本细节以官方文档为准，手册侧重稳定心智模型。

## 验收标准

- 一份文件可独立完成从概念到 minikube + kubectl + Helm 的学习闭环。
- 每个主要组件都有“是什么、为什么、在本项目哪里、如何验证”。
- 每个关键 YAML 字段均有含义和项目实例。
- 所有命令使用当前仓库路径、Namespace、服务名和端口。
- 至少包含一条裸 manifest 部署链路和一条 Helm 部署链路。
- 包含按问题分类的命令速查与故障树。
- 没有 TBD、TODO 或依赖读者先读 W1–W4 的隐含前置。
