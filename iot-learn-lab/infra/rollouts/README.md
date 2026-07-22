# Argo Rollouts（Stage 2 W7）

本目录记录 **Argo Rollouts** 安装与日常命令。  
Argo CD 集群侧安装与 Application 见：[`../argocd/README.md`](../argocd/README.md)。

> **重要：** `kubectl config set-context --namespace=argocd` 只改默认 Namespace，**不会**安装任何 CLI。  
> `kubectl argo rollouts` / `argocd` 都是 **本机二进制**（或 kubectl 插件），需单独安装到 `PATH`。

**环境假设：** WSL2 Ubuntu + minikube（Linux amd64）。Apple Silicon / Windows 原生请换对应 release 资源名。

---

## 1. 谁管什么（Argo CD vs Rollouts）

| 问题 | 找谁 | 典型命令 / 入口 |
|------|------|-----------------|
| Git 改了，集群没 Sync | **Argo CD** | UI / `kubectl -n argocd get application` |
| Application Synced 但版本卡在 10% pause | **Argo Rollouts** | `kubectl argo rollouts get rollout ...` |
| 金丝雀出错，立刻回上一稳定版 | **Argo Rollouts** | `kubectl argo rollouts abort ...` |
| abort 后下次又自动发 v2 | **Git 期望状态未改** | 改回 `values-v1` 再让 Argo CD Sync |
| 控制器 Pod 是否 Ready | 各自 Namespace | `argocd` / `argo-rollouts` |

| 组件 | Namespace | 本机 CLI（可选但推荐） |
|------|-----------|------------------------|
| Argo CD | `argocd` | `argocd` |
| Argo Rollouts | `argo-rollouts` | `kubectl argo rollouts`（插件名 `kubectl-argo-rollouts`） |
| 业务应用 | `iot-learn` | — |

建议默认 Namespace 不要长期停在 `argocd`：

```bash
kubectl config set-context --current --namespace=iot-learn
# 或每次显式写 -n
```

---

## 2. 安装 Argo Rollouts Controller（集群内）

```bash
kubectl create namespace argo-rollouts
kubectl apply -n argo-rollouts -f \
  https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml

kubectl -n argo-rollouts rollout status deploy/argo-rollouts --timeout=300s
kubectl -n argo-rollouts get pods
```

预期：`argo-rollouts-*` 为 `Running` / Ready。

CRD 是否就绪：

```bash
kubectl get crd | grep rollouts
# 应能看到 rollouts.argoproj.io、analysisruns.argoproj.io 等
```

---

## 3. 安装 `kubectl argo rollouts` 插件（本机）

没有插件时会出现：`error: unknown command "argo" for "kubectl"`。

```bash
curl -LO https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-linux-amd64

chmod +x ./kubectl-argo-rollouts-linux-amd64
sudo mv ./kubectl-argo-rollouts-linux-amd64 /usr/local/bin/kubectl-argo-rollouts

# kubectl 约定：PATH 里的 kubectl-<plugin> 会映射成子命令
kubectl argo rollouts version
which kubectl-argo-rollouts
```

若仍提示 unknown command：

```bash
echo "$PATH" | tr ':' '\n' | head
ls -l /usr/local/bin/kubectl-argo-rollouts
# 确认当前 shell 用的就是装了插件的那个 kubectl
type -a kubectl
```

**无插件时的临时替代（功能较弱）：**

```bash
kubectl get rollout -A
kubectl get rollout device-report-service -n iot-learn -o yaml
kubectl -n argo-rollouts logs deploy/argo-rollouts --tail=100 -f
```

---

## 4. Rollouts Dashboard（可选）

```bash
kubectl argo rollouts dashboard
# 默认 http://localhost:3100
```

若插件 dashboard 不可用，可用官方 UI 部署方式（见 [Rollouts Dashboard](https://argo-rollouts.readthedocs.io/en/stable/dashboard/)），学习阶段不强制。

---

## 5. abort / promote / 观察（速查）

业务对象在 **`iot-learn`**（W7 迁权后名为 `device-report-service`）：

```bash
# 观察（推荐开 watch）
kubectl argo rollouts get rollout device-report-service -n iot-learn --watch

# 跳过当前 pause，继续下一步
kubectl argo rollouts promote device-report-service -n iot-learn

# 中止金丝雀，回到上一稳定 ReplicaSet
kubectl argo rollouts abort device-report-service -n iot-learn

# 失败后若需重新按当前 spec 发布
kubectl argo rollouts retry device-report-service -n iot-learn

# 状态摘要
kubectl argo rollouts status device-report-service -n iot-learn
```

官方 Getting Started 的 demo 名称常是 `rollouts-demo`，与本 lab **不是同一个** Rollout：

```bash
kubectl argo rollouts get rollout rollouts-demo -n default --watch   # 仅当你装过官方 demo
kubectl argo rollouts get rollout device-report-service -n iot-learn --watch
```

**GitOps 提醒：** `abort` 只回滚集群发布进度。若 Git 仍是 v2+bug，Argo CD 下次 Sync / Self-heal 可能再次发起升级 —— 结业要把 Git 期望改回健康版本（如 `values-v1`）。

---

## 6. 安装 Argo CD CLI（本机，可选）

集群内 Argo CD 已在 W6 安装即可用 UI。  
本机 `argocd` 二进制 **可选**；未安装时 `argocd: command not found` 属正常。

```bash
curl -sSL -o argocd-linux-amd64 \
  https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64

chmod +x argocd-linux-amd64
sudo mv argocd-linux-amd64 /usr/local/bin/argocd

argocd version --client
```

### 6.1 不装 CLI：用 kubectl + UI（推荐学习路径）

```bash
# 初始 admin 密码
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo

# UI（注意：默认只监听 127.0.0.1；浏览器用 https://localhost:8080）
kubectl -n argocd port-forward svc/argocd-server 8080:443

# Application 状态
kubectl -n argocd get application iot-learn-lab
kubectl -n argocd get application iot-learn-lab \
  -o jsonpath='{.status.sync.status}{" "}{.status.health.status}{"\n"}'
```

### 6.2 使用 CLI：`--core` 模式（kubeconfig 直连）

适合已装好 `argocd`、且当前 context 指向 minikube 时：

```bash
# 可选：CLI 操作 Application 时默认 ns
kubectl config set-context --current --namespace=argocd

argocd login --core
argocd app list
argocd app get iot-learn-lab
argocd app sync iot-learn-lab
```

用完建议把默认 Namespace 改回业务 ns：

```bash
kubectl config set-context --current --namespace=iot-learn
```

### 6.3 使用 CLI：port-forward + 用户名密码

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443
# 另开终端：
PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d)
argocd login localhost:8080 --username admin --password "$PASS" --insecure
argocd app list
```

---

## 7. 本机工具清单（一次核对）

```bash
kubectl version --client
kubectl argo rollouts version          # Rollouts 插件
argocd version --client                # 可选；没有也不阻塞 W6/W7
helm version                           # 本地渲染 / 对照用
```

| 命令 | 作用 | W7 是否必须 |
|------|------|-------------|
| `kubectl` | 一切集群操作 | 必须 |
| `kubectl argo rollouts` | 金丝雀观察 / abort / promote | **强烈建议** |
| `argocd` | Application Sync 等 | 可选（UI + kubectl 可替代） |
| `helm` | `helm template` 自检 Chart | 建议保留 |

---

## 8. 相关文档

| 文档 | 说明 |
|------|------|
| [`../argocd/README.md`](../argocd/README.md) | Argo CD 集群安装、登录、Application |
| `docs/superpowers/guides/2026-07-22-stage2-w7-rollouts.md` | W7 概念指南 |
| `docs/superpowers/plans/2026-07-22-stage2-w7-rollouts.md` | W7 实施计划 |
| [Rollouts Getting Started](https://argo-rollouts.readthedocs.io/en/stable/getting-started/) | 官方入门 |
| [Argo CD Getting Started](https://argo-cd.readthedocs.io/en/stable/getting_started/) | 官方入门 |
