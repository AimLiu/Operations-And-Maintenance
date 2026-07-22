# Stage 2 W6 前置知识：GitOps 与 Argo CD

**读者：** 已完成 W5（三层 Helm values、checksum、一条命令切 v2+canary），能用 `helm upgrade` 管 `iot-learn` Release，但还没用过 GitOps 控制器  
**范围：** Stage 2 W6（安装 Argo CD、Application 指向 Helm Chart、Sync / Prune / Self-heal）  
**对照计划：** `docs/superpowers/plans/2026-07-21-stage2-w6-argocd.md`  
**不讲：** Argo Rollouts 金丝雀、AnalysisTemplate（W7）；Jaeger（W8）；GitHub Actions（W9–W10）

读完你应能回答八件事：

1. GitOps 和「本机 `helm upgrade`」差在哪  
2. Argo CD 在集群里干什么（对比 kubectl / Helm CLI）  
3. Application、Project、Sync、OutOfSync、Healthy 各是什么  
4. Prune 与 Self-heal 分别防什么误操作  
5. 为什么 Argo CD 用 Helm 时 `helm list` 可能看不到同名 Release  
6. `valueFiles` 顺序如何对齐 W5 三层 values  
7. 私有 GitHub 仓库为什么要配 Repository Secret  
8. 从「Helm CLI 管对象」迁到「Argo 管对象」时为什么要先卸 Helm Release  

---

## 1. 先看一串你马上要敲的命令

```bash
# 安装 Argo CD
kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 等就绪 + 取初始密码 + port-forward UI
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
kubectl -n argocd port-forward svc/argocd-server 8080:443

# 声明 Application（仓库路径见计划；需先 commit+push W5）
kubectl apply -f iot-learn-lab/infra/argocd/application-iot-learn-lab.yaml
kubectl -n argocd get application iot-learn-lab

# 场景脚本（Release 已由 Argo 接管后）
iot-learn-lab/scripts/stage2/scenario-k6-argocd-sync.sh
```

成功时大致会看到：

```text
NAME            SYNC STATUS   HEALTH STATUS
iot-learn-lab   Synced        Healthy
...
K6 PASS: Argo CD Application Synced+Healthy; Ingress health OK
```

下面解释：**为什么不再「人肉 helm upgrade」，而是「改 Git → 控制器调和」。**

---

## 2. 和 W4–W5 / Phase 4 对比

| 以前 | W6 |
|------|-----|
| 本机 `helm upgrade -f values-v2.yaml` | **Git 里改 values** → Argo Sync |
| 真相源 = 你终端里敲的命令 | 真相源 = **Git 提交** |
| Helm Release 历史在集群 Secret | Argo Application 历史 + Git history |
| Phase 4 / W5 切版本靠人 | 同一套 Chart；**谁触发升级**变成 GitOps |
| W7 才做流量金丝雀 | W6 只练「同步与自愈」 |

口诀：

> **W5 教会「怎么声明」；W6 教会「谁负责把声明落到集群」。**

---

## 3. GitOps 一句话

```text
期望状态写在 Git
        │
        ▼
Argo CD 对比「Git 渲染结果」vs「集群实况」
        │
        ├─ 一致 → Synced
        └─ 不一致 → OutOfSync →（手动或自动）Sync 把集群改回 Git
```

这和 Kubernetes 控制器的「期望状态 vs 实际状态」是同一类思维，只是期望状态从 etcd 里的 Deployment，扩展到了 **Git 仓库里的 Chart+Values**。

---

## 4. 工具边界：kubectl / Helm / Argo CD

| 工具 | 角色 |
|------|------|
| **kubectl** | 直接改集群对象（手术刀） |
| **Helm CLI** | 本机渲染 Chart 并提交对象，自管 Release |
| **Argo CD** | 持续对比 Git 与集群；用 `helm template` **只渲染**，再把 YAML 交给集群；**生命周期由 Argo 管** |

官方明确：Argo CD 对 Helm 的用法是 inflate（`helm template`），不是 `helm install`。因此：

```bash
helm list -n iot-learn
# 可能为空或不含 iot-learn —— 这很正常
```

看状态请用：

```bash
kubectl -n argocd get application iot-learn-lab
argocd app get iot-learn-lab   # 若已装 CLI
```

---

## 5. 核心对象：Application

Application 是 Argo CD 的一等公民，回答四个问题：

| 字段 | 含义 | 本仓库示例 |
|------|------|------------|
| `source.repoURL` | Git 仓库 | `https://github.com/AimLiu/Operations-And-Maintenance.git` |
| `source.path` | Chart 目录（含 `Chart.yaml`） | `iot-learn-lab/infra/helm/iot-learn-lab` |
| `source.targetRevision` | 分支 / tag / commit | `main` |
| `source.helm.valueFiles` | 传给 `helm template -f` 的文件 | `values.yaml` → `values-minikube.yaml` → `values-v1.yaml` |
| `destination.namespace` | 部署到哪 | `iot-learn` |
| `destination.server` | 哪个集群 | 本集群：`https://kubernetes.default.svc` |

数据流：

```text
Git: values*.yaml + templates/
        │  Argo repo-server: helm template ... -f ...
        ▼
普通 Kubernetes YAML
        │  Argo application-controller Sync
        ▼
iot-learn Namespace 里的 Deployment / Service / ConfigMap / Ingress
```

**注意：** `valueFiles` 路径相对 **Chart 目录**（`path`），不是仓库根。顺序与 W5 相同：**后写的覆盖先写的**。

---

## 6. Sync / OutOfSync / Healthy

| 词 | 含义 |
|----|------|
| **Synced** | Git 渲染出的期望对象与集群实况一致（在 Argo 的对比规则下） |
| **OutOfSync** | 有人改了集群，或 Git 有新提交尚未同步 |
| **Healthy** | 工作负载健康（如 Deployment 可用）；与 Synced 正交 |
| **Progressing** | 滚动更新等进行中 |
| **Degraded** | 健康检查失败 |

常见组合：

| Sync | Health | 说明 |
|------|--------|------|
| Synced + Healthy | 理想态 |
| OutOfSync + Healthy | Git 已变或有人 kubectl 手改；业务可能仍正常 |
| Synced + Degraded | Git 与集群一致，但 Pod Crash / 探针失败 |
| OutOfSync + Degraded | 两边都有问题，先看 Application 事件与 Pod 日志 |

---

## 7. Prune 与 Self-heal

写在 `syncPolicy.automated`（也可先 Manual Sync，再打开自动）：

| 策略 | 作用 | 风险 |
|------|------|------|
| **automated.prune: true** | Git 里删掉的资源，Sync 时从集群删除 | 误删 Git 文件会删集群对象 |
| **automated.selfHeal: true** | 有人 `kubectl edit` 偏离 Git，控制器再 Sync 拉回 | 紧急线上热修会被盖掉（应改 Git） |
| 仅 Manual Sync | 你点 Sync / `argocd app sync` 才改 | 最安全，适合 W6 前半 |

W6 推荐节奏：

1. Application 先用 **手动 Sync** 跑通 K6  
2. 再打开 automated + selfHeal，故意 `kubectl scale` 偏离，观察自愈  
3. 理解后再决定是否长期开 prune  

---

## 8. 仓库可达性（本仓库是 GitHub SSH remote）

本机 `git remote` 多为：

```text
git@github.com:AimLiu/Operations-And-Maintenance.git
```

Argo CD Application 建议写 **HTTPS**：

```text
https://github.com/AimLiu/Operations-And-Maintenance.git
```

若仓库是 **私有**：

1. 在 GitHub 建 fine-grained / classic PAT（至少 `contents:read`）  
2. 在 Argo CD 登记 Repository（UI Settings → Repositories，或 Secret）  
3. 再 Sync；否则 Application 会卡在 `ComparisonError` / authentication failed  

若仓库是 **公开**：可不配 Secret，但仍建议固定 `targetRevision: main`。

未 **push** 到远程的本地 commit，Argo **看不见**。W6 实验前必须把 W5 Chart/values 推到 `origin/main`（或你 Application 跟踪的分支）。

---

## 9. 为何要从 Helm CLI「迁权」给 Argo

若集群里仍有 Helm Release `iot-learn` 管着同名 Deployment，再让 Argo Sync 同一批对象，常见：

- ownership / annotation 冲突  
- 两边各改各的，状态混乱  

W6 标准做法（学习环境）：

```text
确认 Git 已有正确 Chart
  → helm uninstall iot-learn -n iot-learn   （短暂中断业务）
  → kubectl apply Application
  → Argo Sync 重建对象
  → 以后只改 Git，不再 helm upgrade 同名应用
```

裸 `infra/k8s/` 继续只作教材，**不要**和 Argo Application 混 apply 同名资源。

---

## 10. UI 与 CLI 怎么进

### port-forward（minikube 最省事）

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443
# 浏览器：https://localhost:8080
# 用户：admin
# 密码：argocd-initial-admin-secret
```

证书是自签的，浏览器会告警，学习环境可继续访问。

### argocd CLI（可选）

```bash
argocd login localhost:8080 --username admin --insecure
argocd app list
argocd app get iot-learn-lab
argocd app sync iot-learn-lab
```

W6 不强制装 CLI；`kubectl` + UI 足够完成 K6。

---

## 11. 和「改 values 切 v2」的衔接

W5：

```bash
helm upgrade ... -f values-v2.yaml
```

W6：

```text
1. 改 Git 里 values-v2 / 或改 Application 的 valueFiles 最后一项为 values-v2.yaml
2. commit + push
3. Argo 显示 OutOfSync（若未开 auto）
4. Sync
5. checksum 滚动 Pod（与 W5 相同）
```

W6 场景脚本默认验证 **Synced + Healthy + Ingress health**；切 v2+canary 可作为加分手工实验，完整流量金丝雀留给 W7。

---

## 12. 排障顺序

```text
1. kubectl -n argocd get pods
   → argocd-server / repo-server / application-controller 是否 Ready？
2. kubectl -n argocd get application iot-learn-lab -o yaml
   → sync.status / health / conditions 里是否有 repo 认证错误？
3. 浏览器 / CLI 看 Application → APP DETAILS → MANIFEST
   → helm template 结果是否含三服务？
4. Git 远程是否包含你以为的 commit？（Argo 只看 remote）
5. destination.namespace 是否为 iot-learn？valueFiles 顺序对不对？
6. 若 Synced 但业务挂：回到 W2/W5 排障（中间件、checksum、镜像）
```

---

## 13. 命令速查

```bash
kubectl -n argocd get application
kubectl -n argocd describe application iot-learn-lab
kubectl -n argocd get appprojects

# 手动同步（无 CLI 时）
kubectl -n argocd patch application iot-learn-lab --type merge \
  -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"main"}}}'

# 或 UI 点 SYNC / 使用 argocd app sync

kubectl get pods,svc,ingress -n iot-learn
curl -sk -H "Host: device-report.iot-learn.local" \
  "https://localhost:8080/"   # 注意：这是 Argo UI，不是业务 Ingress

# 业务仍走 minikube Ingress：
curl -s -H "Host: device-report.iot-learn.local" \
  "http://$(minikube ip)/actuator/health"
```

---

## 14. W6 故意还没碰的东西

| 概念 | 何时 |
|------|------|
| ApplicationSet / App of Apps | 多环境规模化后 |
| Argo Rollouts canary weight | W7 |
| Image Updater / CI 改 image tag | W9–W10 |
| 多集群 destination | 生产进阶 |
| SSO / RBAC 细粒度 | 生产安全 |

---

## 15. 自测题（合上文档回答）

1. GitOps 的「唯一真相源」是什么？本机 helm 历史算吗？  
2. Synced 和 Healthy 可以一个好一个坏吗？举一例。  
3. Self-heal 打开后，你 `kubectl scale` 会被怎样？  
4. 为什么私有仓库 Application 会 ComparisonError？  
5. Argo 管 Helm Chart 后，为什么 `helm list` 可能是空的？  
6. `valueFiles` 里 `values-v1` 与 `values-v2` 谁应放在最后？  
7. 迁权前为什么建议 `helm uninstall`？  

答不上来就回到对应小节；能答上来再执行 `2026-07-21-stage2-w6-argocd.md`。
