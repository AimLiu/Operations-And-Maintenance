# Stage 2 W6：Argo CD GitOps + Application 指向 Helm Chart Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 minikube 安装 **Argo CD**，用 Application 声明式部署 `iot-learn-lab` Helm Chart（W5 三层 values）；验证 **Sync / OutOfSync / Healthy**，完成一次「改 Git → Sync → 集群变化」，并跑通 `scenario-k6-argocd-sync.sh`。

**Architecture:** Argo CD 装在 `argocd` Namespace；Application `iot-learn-lab` 跟踪 Git 仓库中 `iot-learn-lab/infra/helm/iot-learn-lab`，经 `helm template` + `valueFiles`（`values.yaml` → `values-minikube.yaml` → `values-v1.yaml`）渲染后同步到 `iot-learn`。业务中间件仍在 WSL Docker（混合架构不变）。W6 **先手动 Sync**，再可选打开 automated selfHeal；**不做** Rollouts 金丝雀（W7）。

**Tech Stack:** Argo CD（stable manifest）、现有 Helm Chart、kubectl、minikube、GitHub 远程仓库

**Spec 来源:** `docs/superpowers/specs/2026-07-13-stage2-k8s-gitops-design.md`（W6 段）

**前置知识指南:** `docs/superpowers/guides/2026-07-21-stage2-w6-argocd.md`

**前置条件（W5 已完成）：**

- [x] Chart 含 `values-minikube.yaml`、三层 `-f`、checksum、`scenario-k5` 可用
- [x] `helm upgrade --install iot-learn ... values-v1` 能稳定部署三服务
- [x] Git remote 存在（当前：`git@github.com:AimLiu/Operations-And-Maintenance.git`）
- [ ] **W5 相关改动已 commit 并 push 到 Application 跟踪的分支**（默认 `main`）——Argo 只读远程
- [ ] 仓库对 Argo 可读：公开，或已准备 GitHub PAT / SSH 凭据

**时间预算:** 1 周 × 10–15h

**W6 边界:**

| W6 做 | W6 不做 |
|-------|---------|
| 安装 Argo CD（官方 install.yaml） | Argo Rollouts / AnalysisTemplate（W7） |
| `infra/argocd/application-iot-learn-lab.yaml` | ApplicationSet / App of Apps |
| Git → Sync → 集群；Prune / Self-heal 实验 | Jaeger / CI 改 image tag（W8–W10） |
| `scenario-k6-argocd-sync.sh` | 用 Argo 替换 Phase 4 APISIX 流量分割 |
| 从 Helm CLI 迁权到 Argo | 删除 `infra/k8s/` 对照教材 |

---

## W6 拓扑（读完再动手）

```text
GitHub: AimLiu/Operations-And-Maintenance  (branch main)
  path: iot-learn-lab/infra/helm/iot-learn-lab
  valueFiles: values.yaml + values-minikube.yaml + values-v1.yaml
        │
        │  Argo CD (ns=argocd)  helm template → Sync
        ▼
┌─ Namespace iot-learn ─────────────────────────────────────────┐
│  ConfigMap / Deployment / Service / Ingress（与 W5 等价）      │
└────────────────────────────┬──────────────────────────────────┘
                             │ host.minikube.internal
┌────────────────────────────▼──────────────────────────────────┐
│  WSL Docker 中间件（不变）                                      │
└───────────────────────────────────────────────────────────────┘
```

**与 W5 命令对照：**

| W5 | W6 |
|----|-----|
| `helm upgrade -f values-v2.yaml` | 改 Git 中 values / Application `valueFiles` → Sync |
| `helm history` / `rollback` | Git revert + Sync；或 Argo 历史（了解即可） |
| 本机是操作入口 | **Git + Argo UI/CLI** 是操作入口 |

---

## 文件结构（W6 新增 / 修改）

```text
iot-learn-lab/
├── infra/
│   └── argocd/
│       ├── README.md                         # 安装、登录、迁权注意
│       ├── repository-secret.example.yaml    # 私有库凭据模板（勿提交真密钥）
│       └── application-iot-learn-lab.yaml    # Application
├── scripts/stage2/
│   └── scenario-k6-argocd-sync.sh
└── docs/
    └── stage2-interview-notes.md             # 追加 W6

docs/superpowers/
├── plans/2026-07-21-stage2-w6-argocd.md      # 本文件
├── guides/2026-07-21-stage2-w6-argocd.md
└── specs/2026-07-13-stage2-k8s-gitops-design.md  # 链到 W6 文档；Rollouts 脚本改为 k7
```

---

## 学习场景 K6：Argo Sync 基线（W6 Day 5–6）

| 项 | 内容 |
|----|------|
| **操作** | Argo Ready → Application Synced/Healthy → Ingress health；可选：改 Git 制造 OutOfSync 再 Sync |
| **预期** | `scenario-k6-argocd-sync.sh` → `K6 PASS` |
| **面试** | GitOps 真相源？Synced vs Healthy？Self-heal？为何 helm list 可能为空？ |

---

### Task 1: 推送 W5 到远程（Argo 可读）

**Files:**（你本地已有的 W5 改动）

- [ ] **Step 1: 确认工作区与远程分支**

```bash
cd /mnt/d/Project_Install/JAVA_Develop/Operations-And-Maintenance/Operations-And-Maintenance
git status -sb
git remote -v
git log -1 --oneline
```

Expected: `origin` 指向 `AimLiu/Operations-And-Maintenance`；当前分支可跟踪 `main`

- [ ] **Step 2: 提交并推送 W5 资产（若尚未 push）**

确保至少包含：

- `iot-learn-lab/infra/helm/iot-learn-lab/values*.yaml`
- checksum 相关 templates
- `application-k8s.yml` 的 `APP_*` 绑定
- `docs/stage2-helm-cheatsheet.md`、`scenario-k5-helm-values-switch.sh`

```bash
git add iot-learn-lab/infra/helm/iot-learn-lab \
  iot-learn-lab/device-report-service/src/main/resources/application-k8s.yml \
  iot-learn-lab/docs/stage2-helm-cheatsheet.md \
  iot-learn-lab/scripts/stage2/scenario-k5-helm-values-switch.sh \
  iot-learn-lab/infra/k8s/README.md \
  iot-learn-lab/README.md \
  iot-learn-lab/docs/stage2-interview-notes.md \
  docs/superpowers/plans/2026-07-19-stage2-w5-helm-values.md \
  docs/superpowers/guides/2026-07-19-stage2-w5-helm-values.md

git status
# 按仓库惯例写 commit message 后：
git push -u origin HEAD
```

Expected: GitHub 上 `main`（或你的跟踪分支）能看到 Chart 与 `values-minikube.yaml`

- [ ] **Step 3: 记下 HTTPS 仓库 URL（给 Application 用）**

```text
https://github.com/AimLiu/Operations-And-Maintenance.git
```

（即使本机 remote 是 `git@...`，Application 仍推荐 HTTPS + PAT。）

---

### Task 2: 安装 Argo CD

**Files:**
- Create: `iot-learn-lab/infra/argocd/README.md`（前半：安装）

- [ ] **Step 1: 确认集群**

```bash
minikube status
kubectl get nodes
kubectl get ns iot-learn
```

Expected: minikube Running；`iot-learn` 已存在（W1–W5）

- [ ] **Step 2: 安装官方 manifest**

```bash
kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

Expected: 大量 `created` / `serverside-applied`；无持续报错

> 版本细节以 [Argo CD Getting Started](https://argo-cd.readthedocs.io/en/stable/getting_started/) 为准；学习环境用 `stable` 即可。

- [ ] **Step 3: 等待核心组件 Ready**

```bash
kubectl -n argocd get pods
kubectl -n argocd rollout status deployment/argocd-server --timeout=300s
kubectl -n argocd rollout status deployment/argocd-repo-server --timeout=300s
kubectl -n argocd rollout status deployment/argocd-applicationset-controller --timeout=300s || true
```

Expected: `argocd-server`、`argocd-repo-server`、`argocd-application-controller` 相关 Pod `Running` / Ready

- [ ] **Step 4: 取初始 admin 密码**

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
echo
```

Expected: 打印一串密码；用户名为 `admin`

- [ ] **Step 5: port-forward UI（另开终端保持）**

```bash
kubectl -n argocd port-forward --address 0.0.0.0 svc/argocd-server 8080:443
```

浏览器打开 `https://192.168.19.64:8080`（自签证书告警可继续）→ 用 `admin` + 上一步密码登录。

- [ ] **Step 6: 写入 `infra/argocd/README.md` 安装节**

```markdown
# Argo CD（Stage 2 W6）

## 安装

\`\`\`bash
kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd rollout status deployment/argocd-server --timeout=300s
\`\`\`

## 登录

\`\`\`bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo
kubectl -n argocd port-forward svc/argocd-server 8080:443
# https://localhost:8080  user=admin
\`\`\`

## 业务 Application

见同目录 \`application-iot-learn-lab.yaml\`。  
**先 push Chart 到 Git，再 apply Application。**  
从 Helm CLI 迁权：先 \`helm uninstall iot-learn -n iot-learn\`，再 Sync。
```

---

### Task 3: 配置私有仓库凭据（若需要）

**Files:**
- Create: `iot-learn-lab/infra/argocd/repository-secret.example.yaml`

> 若仓库已是 **公开**，本 Task 可跳过，直接 Task 4。  
> `AimLiu/Operations-And-Maintenance` 若为私有，必须完成本 Task，否则 Application 无法 fetch。

- [ ] **Step 1: 在 GitHub 创建 PAT**

GitHub → Settings → Developer settings → Personal access tokens：

- 权限至少能读该仓库内容（classic：`repo`；fine-grained：该库 `Contents: Read`）
- 复制 token，**只放本机环境变量，不要写入将要 push 的 YAML**

- [ ] **Step 2: 写入示例文件（无真实密钥）**

```yaml
# 示例：复制为 repository-secret.yaml（已加入 .gitignore 建议）后填入，勿提交真 token
apiVersion: v1
kind: Secret
metadata:
  name: repo-ops-and-maintenance
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: https://github.com/AimLiu/Operations-And-Maintenance.git
  username: git
  password: "REPLACE_WITH_GITHUB_PAT"
```

- [ ] **Step 3: 本机生成并 apply（不提交含密的文件）**

```bash
# 在 WSL，勿把含 PAT 的文件 git add
export GITHUB_PAT='ghp_your_token_here'
kubectl -n argocd create secret generic repo-ops-and-maintenance \
  --from-literal=type=git \
  --from-literal=url=https://github.com/AimLiu/Operations-And-Maintenance.git \
  --from-literal=username=git \
  --from-literal=password="${GITHUB_PAT}" \
  --dry-run=client -o yaml | \
  kubectl label --local -f - argocd.argoproj.io/secret-type=repository -o yaml | \
  kubectl apply -f -
```

或在 Argo UI：Settings → Repositories → Connect Repo → HTTPS + 用户名/PAT。

Expected: UI 中该仓库 Connection Status 为 Successful

- [ ] **Step 4: 确认 `.gitignore` 忽略本地密钥文件（若你创建了）**

在仓库根 `.gitignore` 增加（若尚无）：

```gitignore
iot-learn-lab/infra/argocd/repository-secret.yaml
**/repository-secret.yaml
```

---

### Task 4: 编写 Application 清单

**Files:**
- Create: `iot-learn-lab/infra/argocd/application-iot-learn-lab.yaml`

- [ ] **Step 1: 写入 Application（手动 Sync；对齐 W5 三层 values）**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: iot-learn-lab
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/AimLiu/Operations-And-Maintenance.git
    targetRevision: main
    path: iot-learn-lab/infra/helm/iot-learn-lab
    helm:
      releaseName: iot-learn
      valueFiles:
        - values.yaml
        - values-minikube.yaml
        - values-v1.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: iot-learn
  # W6 前半：不自动同步，便于观察 OutOfSync
  syncPolicy:
    syncOptions:
      - CreateNamespace=true
    # 打开自动同步时取消注释：
    # automated:
    #   prune: true
    #   selfHeal: true
```

- [ ] **Step 2: commit + push Application 清单本身**

```bash
git add iot-learn-lab/infra/argocd/application-iot-learn-lab.yaml \
  iot-learn-lab/infra/argocd/README.md \
  iot-learn-lab/infra/argocd/repository-secret.example.yaml
git commit -m "$(cat <<'EOF'
feat(stage2-w6): add Argo CD Application for iot-learn Helm chart

EOF
)"
git push
```

> Application 可以先用 `kubectl apply` 本地文件装上；推进 Git 是为了 GitOps 完整性。

---

### Task 5: 从 Helm CLI 迁权并首次 Sync

**Files:**（无新业务代码）

- [ ] **Step 1: 记录当前业务是否健康（迁权前）**

```bash
kubectl get pods -n iot-learn
curl -s -o /dev/null -w "%{http_code}\n" \
  -H "Host: device-report.iot-learn.local" \
  "http://$(minikube ip)/actuator/health"
```

Expected: Pod Ready；health 尽量 `200`（若尚未装 Ingress 则改用 port-forward）

- [ ] **Step 2: 卸载 Helm CLI Release（避免双管）**

```bash
helm list -n iot-learn
helm uninstall iot-learn -n iot-learn || true
kubectl get all -n iot-learn
```

Expected: Helm Release 消失；由 Helm 创建的对象被删除（短暂空窗）。Namespace `iot-learn` 可保留。

- [ ] **Step 3: apply Application**

```bash
kubectl apply -f iot-learn-lab/infra/argocd/application-iot-learn-lab.yaml
kubectl -n argocd get application iot-learn-lab
```

Expected: Application 出现；初期可能是 `OutOfSync` 或 `Unknown`

- [ ] **Step 4: 手动 Sync**

**方式 A — UI：** Applications → `iot-learn-lab` → SYNC → Synchronize  

**方式 B — CLI（可选）：**

```bash
argocd login localhost:8080 --username admin --insecure
argocd app sync iot-learn-lab --prune
```

**方式 C — kubectl（无 argocd CLI 时）：**

```bash
kubectl -n argocd patch application iot-learn-lab --type merge \
  -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"syncStrategy":{"hook":{}}}}}'
```

- [ ] **Step 5: 等待 Healthy**

```bash
kubectl -n argocd get application iot-learn-lab -w
# Ctrl+C 退出 watch 后：
kubectl -n argocd get application iot-learn-lab \
  -o jsonpath='{.status.sync.status}{" "}{.status.health.status}{"\n"}'
kubectl get pods -n iot-learn
```

Expected: `Synced Healthy`；三服务 Pod `1/1`

- [ ] **Step 6: 确认 helm list 可能为空（预期）**

```bash
helm list -n iot-learn
```

Expected: 无 `iot-learn` Release（或空表）。对象由 Argo 管理，属正常。

---

### Task 6: Git 变更 → OutOfSync → Sync 实验

**Files:**
- Modify（临时）: `iot-learn-lab/infra/helm/iot-learn-lab/values-v1.yaml`（仅 `deviceReport.replicaCount`）

- [ ] **Step 1: 改 Git 制造差异**

将 `values-v1.yaml` 中：

```yaml
deviceReport:
  replicaCount: 1
```

若无该字段，在 `values-v1.yaml` 增加：

```yaml
deviceReport:
  versionLabel: v1
  appVersion: v1
  canaryBugEnabled: false
  replicaCount: 2
```

```bash
git add iot-learn-lab/infra/helm/iot-learn-lab/values-v1.yaml
git commit -m "$(cat <<'EOF'
chore(stage2-w6): bump device-report replicas to 2 for Argo sync demo

EOF
)"
git push
```

- [ ] **Step 2: 刷新 Application，确认 OutOfSync**

UI 点 Refresh，或：

```bash
kubectl -n argocd annotate application iot-learn-lab \
  argocd.argoproj.io/refresh=hard --overwrite
sleep 5
kubectl -n argocd get application iot-learn-lab \
  -o jsonpath='{.status.sync.status}{"\n"}'
```

Expected: `OutOfSync`

- [ ] **Step 3: Sync 并验证副本**

UI Sync，或 `argocd app sync iot-learn-lab`

```bash
kubectl get deploy device-report-service -n iot-learn \
  -o jsonpath='{.spec.replicas}{"\n"}'
kubectl get pods -n iot-learn -l app=device-report-service
```

Expected: replicas=`2`；两个 Pod（或滚动中）

- [ ] **Step 4: 改回 replicaCount=1，再 push + Sync（恢复基线）**

```bash
# 编辑 values-v1.yaml 回到 replicaCount: 1（或删除该覆盖）
git add iot-learn-lab/infra/helm/iot-learn-lab/values-v1.yaml
git commit -m "$(cat <<'EOF'
chore(stage2-w6): restore device-report replicas to 1

EOF
)"
git push
# Refresh + Sync
```

Expected: 回到 1 副本；Application `Synced`

---

### Task 7: Self-heal 小实验（可选但推荐）

**Files:**
- Modify: `iot-learn-lab/infra/argocd/application-iot-learn-lab.yaml`（打开 automated）

- [ ] **Step 1: 打开 automated.selfHeal（可先 prune: false）**

```yaml
  syncPolicy:
    syncOptions:
      - CreateNamespace=true
    automated:
      prune: false
      selfHeal: true
```

```bash
kubectl apply -f iot-learn-lab/infra/argocd/application-iot-learn-lab.yaml
# 将该变更也 commit+push，保持 Git 与集群 Application 一致（若你也用 Git 管 Application）
```

- [ ] **Step 2: 故意偏离**

```bash
kubectl scale deployment/device-report-service -n iot-learn --replicas=3
kubectl get pods -n iot-learn -l app=device-report-service
```

- [ ] **Step 3: 等待自愈**

```bash
sleep 30
kubectl get deploy device-report-service -n iot-learn \
  -o jsonpath='{.spec.replicas}{"\n"}'
kubectl -n argocd get application iot-learn-lab \
  -o jsonpath='{.status.sync.status}{" "}{.status.health.status}{"\n"}'
```

Expected: 副本被拉回 Git 中的值（通常 1）；再次 Synced

- [ ] **Step 4: 学习阶段可改回手动 Sync**（降低误删风险）

将 `automated` 段注释掉并 apply；需要自动同步时再打开。

---

### Task 8: 场景脚本 K6 + 文档收尾

**Files:**
- Create: `iot-learn-lab/scripts/stage2/scenario-k6-argocd-sync.sh`
- Modify: `iot-learn-lab/docs/stage2-interview-notes.md`
- Modify: `iot-learn-lab/infra/k8s/README.md`（或 `infra/argocd/README.md` 已含说明）
- Modify: `iot-learn-lab/README.md`（进度表 W6）

- [ ] **Step 1: 创建 `scenario-k6-argocd-sync.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "${SCRIPT_DIR}/env.sh"

APP="${ARGOCD_APP:-iot-learn-lab}"
NS_ARGO="${ARGOCD_NAMESPACE:-argocd}"
NS="${K8S_NAMESPACE}"
HOST="${INGRESS_HOST:-device-report.iot-learn.local}"

echo "== K6: Argo CD Application sync baseline =="

kubectl -n "$NS_ARGO" get deployment argocd-server >/dev/null
kubectl -n "$NS_ARGO" rollout status deployment/argocd-server --timeout=120s

if ! kubectl -n "$NS_ARGO" get application "$APP" >/dev/null 2>&1; then
  echo "K6 FAIL: Application ${APP} not found in ${NS_ARGO}"
  echo "Apply: kubectl apply -f iot-learn-lab/infra/argocd/application-iot-learn-lab.yaml"
  exit 1
fi

SYNC=$(kubectl -n "$NS_ARGO" get application "$APP" -o jsonpath='{.status.sync.status}')
HEALTH=$(kubectl -n "$NS_ARGO" get application "$APP" -o jsonpath='{.status.health.status}')
echo "Application ${APP}: sync=${SYNC} health=${HEALTH}"

[[ "$SYNC" == "Synced" ]] || { echo "K6 FAIL: expected Synced, got ${SYNC}. Sync the app in UI/CLI."; exit 1; }
[[ "$HEALTH" == "Healthy" ]] || { echo "K6 FAIL: expected Healthy, got ${HEALTH}"; exit 1; }

kubectl get deploy -n "$NS" device-report-service command-dispatch-service device-report-consumer
kubectl rollout status deployment/device-report-service -n "$NS" --timeout=120s

echo "-- Ingress health --"
code=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: ${HOST}" \
  "http://${MINIKUBE_IP}/actuator/health" || true)
echo "http=${code}"
[[ "$code" == "200" ]] || {
  echo "K6 WARN: Ingress health not 200 (got ${code}); trying port-forward fallback check is manual"
  echo "K6 FAIL: expected Ingress health 200"
  exit 1
}

echo
echo "K6 PASS: Argo CD Application Synced+Healthy; Ingress health OK"
```

- [ ] **Step 2: 执行**

```bash
chmod +x iot-learn-lab/scripts/stage2/scenario-k6-argocd-sync.sh
iot-learn-lab/scripts/stage2/scenario-k6-argocd-sync.sh
```

Expected: `K6 PASS`

- [ ] **Step 3: 面试笔记追加 W6 场景表**

```markdown
## W6 场景记录

| 场景 | 日期 | 通过？ | 关键现象 |
|------|------|--------|----------|
| K6 Argo Sync 基线 | | ☐ | Application Synced+Healthy；Ingress 200 |
| Git 改 replicas → Sync | | ☐ | OutOfSync → Sync 后副本变化 |
| Self-heal（可选） | | ☐ | kubectl scale 被拉回 Git |

## W6 面试题自测

1. GitOps 的真相源是什么？
2. Synced 与 Healthy 的区别？
3. Self-heal / Prune 各防什么？有什么风险？
4. 为什么 Argo 部署 Helm Chart 后 `helm list` 可能为空？
5. 私有仓库如何让 repo-server 拉到代码？
```

- [ ] **Step 4: README 进度改为 W6 进行中/完成（执行后勾）**

---

## W6 完成标准（Checklist）

- [ ] Argo CD 安装在 `argocd` Namespace，server Ready；能登录 UI
- [ ] 私有库已配置 Repository Secret（或仓库为公开）
- [ ] 存在 `infra/argocd/application-iot-learn-lab.yaml`，`valueFiles` 对齐 W5 三层
- [ ] 已 `helm uninstall` 迁权；Application `Synced` + `Healthy`
- [ ] 完成至少一次：改 Git values → OutOfSync → Sync → 集群变化
- [ ] （推荐）完成一次 selfHeal 演示
- [ ] `scenario-k6-argocd-sync.sh` → `K6 PASS`
- [ ] `stage2-interview-notes.md` 有 W6 章节；`infra/argocd/README.md` 有安装说明

---

## W6 面试话术速记

| 问题 | 答法 |
|------|------|
| 什么是 GitOps？ | 期望状态在 Git；控制器持续对比并同步集群；审计=git log |
| 和 helm upgrade 差？ | helm 是人触发的包操作；Argo 是持续调和，入口是 Git |
| Synced vs Healthy？ | Synced=与 Git 一致；Healthy=工作负载健康；可独立变化 |
| Self-heal？ | 手改集群会被拉回 Git；热修应改 Git 再 Sync |
| 为何 helm list 空？ | Argo 用 helm template，不创建 Helm Release 生命周期 |

---

## 常见踩坑

| 现象 | 原因 | 处理 |
|------|------|------|
| ComparisonError / authentication required | 私有库无凭据 | Task 3 配 PAT Secret |
| Application 永远落后本地 | 只 commit 未 push | `git push`；Refresh |
| Sync 失败：existing resource | Helm CLI 仍占有对象 | `helm uninstall` 后再 Sync |
| Synced 但 Ingress 404 | Host 头 / addon / minikube ip | 回 W3 排障 |
| `valueFiles` 未生效 | 路径不相对 Chart，或顺序错 | 相对 `path` 目录；v1/v2 放最后 |
| finalizer 导致删除 Application 卡住 | 资源清理中 | 等 prune；或按官方文档处理 finalizer |
| port-forward 断了 UI 打不开 | 前台进程退出 | 重新 forward |

---

## 下一步（W7 预告）

- 安装 Argo Rollouts
- 将 `device-report` 的 Deployment 演进为 `Rollout`（canary steps）
- AnalysisTemplate 观察 `version=v2` 错误率；abort / promote
- 脚本：`scenario-k7-rollouts-canary.sh`（对标 Phase 4 C3）

**W7 实施计划：** `docs/superpowers/plans/2026-07-22-stage2-w7-rollouts.md`  
**W7 前置指南：** `docs/superpowers/guides/2026-07-22-stage2-w7-rollouts.md`

---

## Spec 覆盖自检

| Spec 要求（Stage 2 W6 段） | 本计划 Task |
|---------------------------|-------------|
| 安装 Argo CD | Task 2 |
| Application 指向 `infra/helm/` | Task 4 |
| 改 Git values → Sync → 集群变化 | Task 6 |
| Sync / Prune / Self-heal 理论与实验 | 指南 + Task 7 |
| 产出 `application-iot-learn-lab.yaml` | Task 4 |
| 场景验证（本计划增补 K6） | Task 8 |

---

## 执行方式

**Plan complete and saved to `docs/superpowers/plans/2026-07-21-stage2-w6-argocd.md`. Two execution options:**

1. **Subagent-Driven（推荐）** — 按 Task 派发子代理，每 Task 后 review  
2. **Inline Execution** — 本会话按 Task 1→8 连续执行；Checkpoint 建议在 Task 5（首次 Synced）后  

**Which approach?**
