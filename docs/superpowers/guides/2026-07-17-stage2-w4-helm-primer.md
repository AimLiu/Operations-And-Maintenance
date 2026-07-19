# Stage 2 W4 前置知识：Helm 入门、Chart 文件与 Values

**读者：** 已完成 W3（Ingress + NodePort + 外部 Prometheus），能用裸 `kubectl apply` 维护三服务，但还没用 Helm 管过发布  
**范围：** Stage 2 W4（Chart 骨架 + install / upgrade / rollback）+ 初学者需要的 Helm 基础  
**对照计划：** `docs/superpowers/plans/2026-07-17-stage2-w4-helm-chart.md`  
**对照目录：** `iot-learn-lab/infra/helm/iot-learn-lab/`  
**不讲：** Argo CD、Rollouts、子 Chart 依赖、完整多环境矩阵（W5+）

> 如果你尚未学习 Kubernetes 集群组件、对象模型、manifest 和 kubectl，请先读综合手册：  
> `docs/superpowers/guides/2026-07-19-kubernetes-helm-beginner-handbook.md`

读完你应能回答八件事：

1. Helm 是干什么的？和 kubectl / Spring 配置有何不同  
2. 一个 Chart 一般有哪些文件，各自什么作用  
3. Chart、Release、Values、Templates 各是什么  
4. `values.yaml` 里的字段代表什么（含为何有的服务 NodePort、consumer 用 ClusterIP）  
5. `helm upgrade --install` 和 `kubectl apply` 差在哪  
6. 多个 `-f values-*.yaml` 时谁覆盖谁  
7. 为什么已有裸 YAML 对象要先删再交给 Helm；Helm 改 ConfigMap 后为何还要滚 Pod  
8. K4 脚本验证的是什么（相对 K2/K3）  

---

## 0. Helm 是什么？（给初学者）

### 0.1 一句话

**Helm = Kubernetes 的包管理器**（有人把它比作 apt / yum / npm，但管的是「怎么把一堆 K8s 对象装进集群」）。

你已经会：

```bash
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml
kubectl apply -f configmap-env.yaml
kubectl apply -f ingress.yaml
# …三个服务 × 多份文件
```

Helm 让你改成：

```bash
helm upgrade --install iot-learn ./infra/helm/iot-learn-lab \
  -n iot-learn \
  -f values.yaml -f values-v1.yaml
```

**一次命令**按「参数表」生成并提交整包资源，还能 `history` / `rollback`。

### 0.2 它解决什么痛点

| 痛点（裸 YAML） | Helm 怎么缓解 |
|-----------------|---------------|
| 文件多、易漏 apply | 一个 Chart 渲染整包 |
| 改副本/镜像要翻很多文件 | 集中改 `values.yaml` |
| 回滚靠人肉找旧文件 | `helm rollback` |
| 多环境（学习 v1/v2）难 | 多层 `-f values-*.yaml` |

### 0.3 三个容易误会的点

| 误会 | 纠正 |
|------|------|
| Helm 是另一种集群 | ❌ 仍部署到你现有的 minikube；底下还是 Deployment/Service |
| `values.yaml` = Spring `application.yml` | ❌ values 是 **部署参数**；应用配置仍经 ConfigMap / `application-k8s.yml` |
| 有了 Helm 就不需要 Ingress/Service | ❌ Helm 只是用模板把它们「印」出来 |

### 0.4 和厨房类比（贯穿全文）

| Helm 概念 | 类比 |
|-----------|------|
| Chart | 菜谱（模具 + 默认配料） |
| `values.yaml` | 配料表（盐放多少、几人份） |
| `templates/` | 按配料表填写的空白单据 |
| `helm upgrade --install` | 按菜谱做一锅 / 改配料重做 |
| Release | 已经端上桌的那一锅（有历史：第 1 锅、第 2 锅…） |
| `helm rollback` | 回到某一锅的配方再做一遍 |

---

## 1. 先看一串你马上要敲的命令

```bash
# 渲染看看长什么样（不写集群）
helm template iot-learn iot-learn-lab/infra/helm/iot-learn-lab \
  -f iot-learn-lab/infra/helm/iot-learn-lab/values.yaml \
  -f iot-learn-lab/infra/helm/iot-learn-lab/values-v1.yaml \
  -n iot-learn | less

# 安装 / 升级（同一条命令）
helm upgrade --install iot-learn iot-learn-lab/infra/helm/iot-learn-lab \
  -n iot-learn \
  -f iot-learn-lab/infra/helm/iot-learn-lab/values.yaml \
  -f iot-learn-lab/infra/helm/iot-learn-lab/values-v1.yaml \
  --wait

# 改一处 values 再升级、再回滚
helm upgrade iot-learn ... --set deviceReport.replicaCount=2 --wait
helm rollback iot-learn 1 -n iot-learn

iot-learn-lab/scripts/stage2/scenario-k4-helm-baseline.sh
```

成功时大致会看到：

```text
Release "iot-learn" has been upgraded. Happy Helming!
STATUS: deployed
...
K4 PASS: Helm release healthy; Ingress + NodePort reachable
```

下面所有概念，都是在解释：**为什么不再手改十几份 YAML，而是改 values 让模板「印」出集群对象。**

---

## 2. 和 W1–W3 对比

| 以前 | W4 |
|------|-----|
| `kubectl apply -f infra/k8s/device-report/` | `helm upgrade --install` 一次出齐 |
| 改副本 → 打开 deployment.yaml | 改 `replicaCount` 或 `--set` |
| 回滚 → git 找回旧文件再 apply | `helm rollback`（看 revision） |
| 配置散落在多份 YAML | 收敛到 `values.yaml` + 叠加文件 |

裸 `infra/k8s/` **不删**：继续当「渲染结果对照」和排障参考；**日常部署入口改 Helm**。

---

## 3. Chart 一般需要哪些文件？（对照本仓库）

### 3.1 最少必备

| 路径 | 是否必须 | 作用 |
|------|----------|------|
| `Chart.yaml` | **必须** | Chart 元数据：名字、版本、描述 |
| `templates/` 下至少一份清单 | **必须** | 带 `{{ }}` 的 K8s YAML 模具 |
| `values.yaml` | 强烈建议 | 默认参数；模板用 `.Values.xxx` 读取 |

**没有 `templates/`，只有 values，Helm 渲不出（或几乎渲不出）集群资源。**

### 3.2 本项目目标结构

```text
iot-learn-lab/infra/helm/iot-learn-lab/          ← Chart 根目录
├── Chart.yaml                    # 包身份证
├── values.yaml                   # 默认配料（对齐 W3）
├── values-v1.yaml                # 可选：v1 叠加
├── values-v2.yaml                # 可选：v2 叠加
├── .helmignore                   # 可选：打包时忽略
└── templates/                    # 模具（从 infra/k8s 平移而来）
    ├── _helpers.tpl              # 可复用的名字 / labels
    ├── device-report-configmap.yaml
    ├── device-report-deployment.yaml
    ├── device-report-service.yaml
    ├── device-report-ingress.yaml
    ├── command-dispatch-*.yaml
    └── device-report-consumer-*.yaml
```

### 3.3 每个文件干什么

#### `Chart.yaml` —— Chart 身份证

```yaml
name: iot-learn-lab
version: 0.1.0                 # Chart 自身版本（改模板结构时升）
appVersion: "0.1.0-SNAPSHOT"   # 应用版本（说明性居多）
```

告诉 Helm「这是什么包」。**不写**副本数、DB 地址、Ingress 域名。

#### `values.yaml` —— 默认部署参数（配料表）

镜像、副本、端口、NodePort、中间件地址、Ingress host 等。  
模板里 `{{ .Values.deviceReport.replicaCount }}` 读的就是这里。

> **不是** Spring 的 `application.yml`。  
> Java 真正读到的仍是：渲染出的 **ConfigMap 环境变量** + 镜像内的 `application-k8s.yml`。

常见段（本仓库）：

| 段 | 含义 |
|----|------|
| `namespace` | 部署到哪个 Namespace |
| `global` | 三服务共用（如 `imagePullPolicy`、`springProfilesActive`） |
| `middleware` | DB/Redis/Kafka/Nacos 等地址 → 将写入 ConfigMap |
| `deviceReport` / `commandDispatch` / `deviceReportConsumer` | 各服务的副本、镜像、端口、资源、Ingress 等 |

#### `values-v1.yaml` / `values-v2.yaml` —— 叠加差异

只覆盖「版本相关」几项（如 `versionLabel`），不必复制整份默认值。  
命令：`-f values.yaml -f values-v2.yaml`（**后者覆盖前者**）。

#### `.helmignore` —— 打包排除列表

类似 `.gitignore`。`helm package` 时不把说明文档、`.git` 等打进包。本地目录安装时影响较小。

#### `templates/*.yaml` —— K8s 模具（核心）

把以前的 `infra/k8s/**/*.yaml` 改成带 `{{ .Values... }}` 的模板，例如：

| 模板 | 渲出什么 |
|------|----------|
| `*-configmap.yaml` | 环境变量（DB / Kafka / Feign…） |
| `*-deployment.yaml` | 跑几个 Pod、用什么镜像 |
| `*-service.yaml` | ClusterIP 或 NodePort |
| `*-ingress.yaml` | Ingress 规则 |

#### `templates/_helpers.tpl` —— 公共小函数

定义可复用的 Chart 名、统一 labels，避免每个模板复制一堆 `app.kubernetes.io/...`。  
约定：必须放在 **`templates/` 下**，文件名以 `_` 开头（一般不当成独立资源提交）。

> 若把 `helpers.tpl` 放在 Chart **根目录**，不符合惯例，模板里的 `include` 也常常找不到。请使用 `templates/_helpers.tpl`。

### 3.4 数据怎么流过这些文件

```text
你改 values.yaml（如 replicaCount / dbHost / ingress.host）
        │
        ▼
templates 里的 {{ .Values... }} 被填上
        │
        ▼
生成和 infra/k8s 等价的 YAML
        │
        ▼
集群里出现/更新 Deployment、Service、ConfigMap、Ingress…
        │
        ▼
（若是 envFrom）新 Pod 启动时读到新环境变量 → 应用连上中间件
```

---

## 4. 四个词：Chart / Templates / Values / Release

```text
Chart（安装包）
  ├── Chart.yaml          名字、版本
  ├── values.yaml         默认参数
  └── templates/*.yaml    带 {{ }} 的「模具」
           │
           │  helm 用 Values 填模具
           ▼
      普通 Kubernetes YAML
           │
           │  提交到集群
           ▼
      Release（这次安装的实例，带历史 revision）
```

| 词 | 一句话 |
|----|--------|
| **Chart** | 可版本化的部署包（模具 + 默认配置） |
| **Templates** | 含 Go template 语法的 YAML |
| **Values** | 填模具的参数；可多层 `-f` 覆盖 |
| **Release** | 集群里「装着这个 Chart 的一次安装」，有名字（如 `iot-learn`）和历史 |

口诀：

> **Chart 是菜谱；Values 是配料表；Release 是这锅已经炒出来的菜（还能按锅次回滚）。**

---

## 5. `values.yaml` 里：为何有的 NodePort、consumer 用 ClusterIP？

这是 **Service 类型** 选择，写在 values 里只是方便 Helm 渲染；概念与 W3 相同。

| 服务 | values 里怎么配 | 原因 |
|------|-----------------|------|
| device-report | `nodePort: 30765`（Service type NodePort） | 集群外要访问：Ingress 后端、Prometheus scrape、调试 |
| command-dispatch | `nodePort: 30767` | 集群外 Prometheus scrape；Feign 仍走集群内 DNS |
| device-report-consumer | `serviceType: ClusterIP` | **没有集群外调用方**；只消费 Kafka → 写 PG |

### 5.1 ClusterIP vs NodePort（纠正常见误解）

| | ClusterIP | NodePort |
|--|-----------|----------|
| 集群内 | ✅ `http://svc名:port` | ✅ 也能用 |
| 集群外 | ❌ 默认够不着 | ✅ `节点IP:nodePort` |
| IP 含义 | 有一个**相对稳定的虚 IP**（不是「IP 不固定」） | 同样有 ClusterIP，再加节点端口 |
| 谁在变 | **Pod IP** 才容易变 | 同上 |

```text
ClusterIP：  集群内 → Service 虚 IP → Pod
NodePort：   集群外 → minikube_ip:30765 ─┐
             集群内 → Service 虚 IP     ─┴→ Pod
```

**NodePort 是 Service 的一种类型**（L4 在节点上开端口），不是 Ingress。  
Ingress 是另一层（L7 域名/路径）；Helm 只是把你在 values 里选的类型印进 `Service` 模板。

---

## 6. `helm upgrade --install` 在干什么？

```text
有没有叫 iot-learn 的 Release？
  ├─ 没有 → 等价 helm install
  └─ 有   → 用新 values 渲染 → 与现网 Diff → 创建/更新/删除对象
```

和 `kubectl apply` 的差别（面试常问）：

| | kubectl apply | Helm Release |
|--|---------------|--------------|
| 范围 | 你指定的文件 | Chart 渲染出的**整包** |
| 历史 | 基本没有 | `helm history` / `rollback` |
| 删除 | 要自己记删了啥 | `helm uninstall` 可按 Release 收走 |
| 归属 | 无强归属 | 对象带 Helm label/annotation |

W4 用 `--install` 是为了：**一条命令覆盖「首次部署」和「以后每次改 values」。**

---

## 7. 多个 values 文件：后者覆盖前者

```bash
helm upgrade --install iot-learn ./chart \
  -f values.yaml \
  -f values-v1.yaml
```

```text
values.yaml（底）  ← 默认中间件、端口、Ingress
values-v1.yaml     ← 覆盖 versionLabel / image 等
（后出现的键赢）
```

`--set deviceReport.replicaCount=2` 适合临时实验；**长期状态应写回 values 文件**，否则下次忘了 `--set` 会「变回去」。

---

## 8. 为什么迁移时要先删裸 YAML 对象？

W1–W3 的对象是 `kubectl apply` 建的，**没有**「属于 Release iot-learn」的元数据。

若直接 `helm install` 同名 Deployment/Service：

- 常见报错：资源已存在 / 无法接管  
- 或行为怪异：一边以为自己管、一边其实不是 Helm 历史里的对象  

学习环境干净做法：

```text
删除 deploy/svc/cm/ingress（保留 namespace）
        →
helm upgrade --install 新建并接管
```

生产上有「adopt / 接管」进阶玩法；W4 **不要求**。

---

## 9. Helm 改了 ConfigMap，Pod 会自动用新环境变量吗？

**不会（和 W2 一样）。**

```text
helm upgrade  →  ConfigMap 对象已是新值
        │
        ✖  已运行容器的 envFrom 快照不更新
        │
kubectl rollout restart 或 改 Deployment 触发滚更
```

W5 可给 Deployment 加 **ConfigMap checksum 注解**，让 upgrade ConfigMap 时自动滚 Pod。W4 先建立直觉：

> **Helm 管的是集群对象生命周期；进程内的 env 仍是容器启动时注入的。**

---

## 10. Ingress / NodePort / Helm 的关系（别和 W3 打架）

Helm **没有**取代 Ingress 或 NodePort，它只是用模板把它们「印」出来：

| 入口 | W4 是否还在 | 谁用 |
|------|-------------|------|
| Ingress Host | 在（values 里可改 host） | 业务 HTTP |
| NodePort 30765/30767 | 在 | Prometheus scrape |
| Service DNS 短名 | 在 | Feign |
| consumer ClusterIP | 在 | 仅集群内（若需要） |

改 Ingress 域名：改 `deviceReport.ingress.host` 再 `helm upgrade`，不必手改裸 `ingress.yaml`。

---

## 11. upgrade / rollback 心智模型

```text
helm history iot-learn

REVISION  STATUS      DESCRIPTION
1         superseded  Install complete
2         deployed    Upgrade complete   ← 当前

helm rollback iot-learn 1
        →
把 Release 恢复成 revision 1 渲染出的那套对象
```

注意：rollback **不是**「撤销这一秒的 kubectl」，而是回到 **Helm 记录的某一版渲染结果**。W4 起尽量别混用裸 apply 和 Helm。

---

## 12. K4 相对 K2/K3 多验证了什么？

| 脚本 | 重心 |
|------|------|
| K2 | Feign + Kafka 业务路径 |
| K3 | Ingress + NodePort +（可选）延迟 |
| **K4** | **Helm Release 健康** + 渲染/history 意识；业务仍靠 Ingress/NodePort 冒烟 |

K4 PASS 不替代 K2/K3；迁移后三者都应能过。

---

## 13. 排障顺序

```text
1. helm status / helm history
2. helm template ... | less     → 渲染错了还是集群错了？
3. 确认 templates/ 与 _helpers.tpl 路径是否正确
4. kubectl get/describe/pods
5. 若 ImagePull：minikube image load（与 W1 相同）
6. 若 ConfigMap 新、行为旧：rollout restart
7. 若与裸 YAML 冲突：确认没有第二套手 apply 的同名对象
```

---

## 14. 命令速查

```bash
helm version
helm lint infra/helm/iot-learn-lab
helm template iot-learn infra/helm/iot-learn-lab -f ... -f ... -n iot-learn
helm upgrade --install iot-learn infra/helm/iot-learn-lab -n iot-learn -f ... -f ... --wait
helm status iot-learn -n iot-learn
helm history iot-learn -n iot-learn
helm rollback iot-learn 1 -n iot-learn
helm get values iot-learn -n iot-learn
helm uninstall iot-learn -n iot-learn   # 慎用：会删掉 Release 管理的资源
```

---

## 15. W4 故意还没碰的东西

| 概念 | 何时 |
|------|------|
| 多环境 values 矩阵 / cheatsheet | W5 |
| ConfigMap checksum 自动滚更 | W5 |
| 真切 v2 镜像 + canary-bug | W5 / W7 |
| Argo CD 用 Git 驱动 helm | W6 |
| Rollouts 金丝雀 | W7 |
| 子 Chart / Chart 依赖 | 以后选修 |

---

## 16. 自测题（合上文档回答）

1. Helm 和 `kubectl apply` 最核心的差别是什么？  
2. 一个能安装的 Chart，最少需要哪两类路径/文件？  
3. `values.yaml` 和 `application-k8s.yml` 谁直接给 Java 进程读？  
4. Chart 和 Release 哪个在集群里有「历史版本」？  
5. `-f values.yaml -f values-v2.yaml` 时，同名字段以谁为准？  
6. 为什么 consumer 在 values 里用 ClusterIP，而 report 要用 NodePort？  
7. `helm upgrade` 更新了 ConfigMap 后，旧 Pod 一定读到新 DB_HOST 吗？  
8. `_helpers.tpl` 应该放在 Chart 根目录还是 `templates/` 下？

答不上来就回到对应小节；能答上来再执行 `2026-07-17-stage2-w4-helm-chart.md`。
