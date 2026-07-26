# Stage 2 W10：GitOps CD（GHCR 镜像 → Argo Sync）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 minikube 上的三服务 **从 GHCR 拉取 W9 产出的短 SHA 镜像**，经 Helm values + Argo CD Sync 生效；产出 CD 段 runbook 与 `scenario-k10-gitops-cd.sh`。主路径不再依赖本机 `minikube image load`。

**Architecture:** 沿用单 Application `iot-learn-lab`（单学习环境）。从最近一次成功 CI 读取 short SHA，将 `values.yaml` / `values-minikube.yaml`（或 v1）中三服务 `image` 改为 `ghcr.io/<owner>/<svc>:<sha>`。Private GHCR 时增加 `imagePullSecrets`；学习仓优先 Package **Public**。Sync 后用 `kubectl get pod -o jsonpath` 确认镜像引用。可选加分：CI 自动开 PR 改 tag（非主线）。

**Tech Stack:** GHCR、Helm values、Argo CD、minikube、现有 Chart / Application

**Spec 来源:** `docs/superpowers/specs/2026-07-13-stage2-k8s-gitops-design.md`（Block E / W10）

**前置知识指南:** `docs/superpowers/guides/2026-07-26-stage2-w10-gitops-cd.md`

**前置条件（W9 已完成）：**

- [x] `.github/workflows/iot-learn-lab-ci.yml`：`test` + `build-and-push` 绿  
- [x] GHCR 存在三服务短 SHA tag  
- [x] Argo Application `iot-learn-lab` 可 Sync Chart  
- [ ] 已知最近一次成功 run 的 short SHA（或会用 `gh`/网页查）  
- [ ] 决定 Package 公开或已准备 PAT + pull Secret  

**时间预算:** 1 周 × 8–12h

**W10 边界:**

| W10 做 | W10 不做 |
|--------|----------|
| values 钉 `ghcr.io/...:<sha>` | 再发明一套 CI（W9 已有） |
| pull Secret（若需要） | CI 直接 kubectl（反 GitOps） |
| Argo Sync + 冒烟 | 完整 test/prod 双集群（文档可提） |
| 续写 `stage2-cicd-runbook.md` CD 章 | Block F 终极演练全做（可选冒烟 Rollouts） |
| `scenario-k10-*.sh` | 强制 CI 自动改 values（加分项） |

---

## 设计透镜

| 透镜 | 用法 |
|------|------|
| **Build once, promote many** | 集群只用 CI 已推的 SHA，不在节点上 rebuild |
| **GitOps** | 换版 = 改 Git 期望；Argo 负责调和 |
| **最小权限** | pull 用 read:packages PAT；勿把 write token 塞进集群 |

---

## W10 拓扑

```text
GHCR: ghcr.io/aimliu/<svc>:<sha>          （W9 已有）
              ▲
              │ pull
minikube Pod ─┘
              ▲
              │ 期望来自
Git: values*.yaml  image: ghcr.io/...:<sha>
              ▲
              │ Sync
         Argo CD
```

---

## 文件结构（W10 新增 / 修改）

```text
iot-learn-lab/
├── infra/helm/iot-learn-lab/
│   ├── values.yaml / values-minikube.yaml / values-v1.yaml   # image 改 GHCR
│   └── templates/*-deployment.yaml / device-report-rollout.yaml  # 可选 imagePullSecrets
├── infra/argocd/
│   └── application-iot-learn-lab.yaml   # 一般不动；确认 valueFiles
├── scripts/stage2/
│   └── scenario-k10-gitops-cd.sh
└── docs/
    ├── stage2-cicd-runbook.md           # 续写 § CD
    └── stage2-interview-notes.md        # W10 行

docs/superpowers/
├── plans/2026-07-26-stage2-w10-gitops-cd.md     # 本文件
├── guides/2026-07-26-stage2-w10-gitops-cd.md
└── specs/2026-07-13-stage2-k8s-gitops-design.md
```

---

## 学习场景 K10：GitOps 用上 GHCR

| 项 | 内容 |
|----|------|
| **操作** | SHA → 改三服务 image → push → Sync → Pod 镜像校验 + health |
| **预期** | `K10 PASS` |
| **面试** | 构建一次？为何不 load？Secret？auto-sync vs 手动？ |

---

### Task 1: 选定要部署的 short SHA

**Files:** 无；记到 runbook

- [ ] **Step 1: 查最近成功 CI**

```bash
gh run list --workflow=iot-learn-lab-ci.yml --branch main --limit 3
# 或打开 Actions 成功 run，复制 github.sha 前 7 位
```

- [ ] **Step 2: 确认 GHCR 上三 tag 存在**（网页 Packages 或）

```bash
# 需登录 ghcr；或浏览器打开 package 版本列表
echo "Expect tags for: device-report-service, command-dispatch-service, device-report-consumer"
```

- [ ] **Step 3: 写下完整三行引用**（替换 OWNER/SHA）

```text
ghcr.io/aimliu/device-report-service:sha-acdf94545e4e751126b3c5596cb25dbe1fd0f202
ghcr.io/aimliu/command-dispatch-service:sha-acdf94545e4e751126b3c5596cb25dbe1fd0f202
ghcr.io/aimliu/device-report-consumer:sha-acdf94545e4e751126b3c5596cb25dbe1fd0f202
```

---

### Task 2: Package 可见性或 pull Secret

**Files:**（private 时）Secret + 模板

- [ ] **Step 1: 学习仓优先 — Package 设为 Public**

GitHub → Packages → 各镜像 → Package settings → Change visibility → Public。

若已 Public → Task 3；跳过 Secret。

- [ ] **Step 2:（备选）创建 pull Secret**

```bash
kubectl -n iot-learn create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io \
  --docker-username=YOUR_GITHUB_USER \
  --docker-password=YOUR_PAT_WITH_read_packages \
  --docker-email=you@example.com
```

- [ ] **Step 3:（备选）Chart 增加 imagePullSecrets**

在 Deployment/Rollout Pod 模板：

```yaml
imagePullSecrets:
  - name: ghcr-pull
```

或 values 开关 `global.imagePullSecrets`。

- [ ] **Step 4: 记录选择（Public vs Secret）到 runbook**

---

### Task 3: 修改 Helm values 中的 image

**Files:**

- Modify: `iot-learn-lab/infra/helm/iot-learn-lab/values.yaml`  
  和/或 Argo 实际使用的 `values-minikube.yaml` / `values-v1.yaml`（以 Application `valueFiles` 为准）

- [ ] **Step 1: 确认 Argo 的 valueFiles 顺序**

见 `infra/argocd/application-iot-learn-lab.yaml`（通常 `values.yaml` + `values-minikube.yaml` + `values-v1.yaml`）。**最后覆盖的文件说了算。**

- [ ] **Step 2: 改三处 image**

```yaml
deviceReport:
  image: ghcr.io/aimliu/device-report-service:<SHA>
commandDispatch:
  image: ghcr.io/aimliu/command-dispatch-service:<SHA>
deviceReportConsumer:
  image: ghcr.io/aimliu/device-report-consumer:<SHA>
```

- [ ] **Step 3:（可选）imagePullPolicy**

新 SHA tag：保持 `IfNotPresent` 即可。若遇缓存怪异，临时 `Always` 排查。

- [ ] **Step 4: 本地渲染检查（可选）**

```bash
helm template iot-learn iot-learn-lab/infra/helm/iot-learn-lab \
  -f iot-learn-lab/infra/helm/iot-learn-lab/values.yaml \
  -f iot-learn-lab/infra/helm/iot-learn-lab/values-minikube.yaml \
  -f iot-learn-lab/infra/helm/iot-learn-lab/values-v1.yaml \
  | grep -E "image:"
```

Expected：出现 `ghcr.io/aimliu/...:<SHA>`。

---

### Task 4: Push → Argo Sync → 验证 Pod

**Files:** 无代码；操作

- [ ] **Step 1: commit + push values（由你执行；代理可不提交时跳过本步说明即可）**

- [ ] **Step 2: Sync**

```bash
# CLI 例：
argocd app sync iot-learn-lab
# 或 UI Sync；若已 automated，等待 Healthy
kubectl -n argocd get application iot-learn-lab
```

- [ ] **Step 3: 确认镜像**

```bash
kubectl -n iot-learn get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'
```

Expected：三服务均为 `ghcr.io/aimliu/...:<SHA>`，状态 Ready。  
`ImagePullBackOff` → 回 Task 2（可见性/Secret/tag 写错）。

- [ ] **Step 4: 冒烟**

```bash
curl -s -o /dev/null -w "%{http_code}\n" \
  -H "Host: device-report.iot-learn.local" \
  "http://$(minikube ip)/actuator/health"
# 期望 200
```

可选：打一枪 `reports-with-dispatch`，Jaeger 仍能看见（回归 W8）。

- [ ] **Step 5: 确认不再依赖 load（叙述）**

本机可不 `image load`；节点从 GHCR pull。

---

### Task 5: `scenario-k10-gitops-cd.sh`

**Files:**

- Create: `iot-learn-lab/scripts/stage2/scenario-k10-gitops-cd.sh`

- [ ] **Step 1: 最小断言**

1. Application Synced + Healthy（或文档化手动检查）  
2. 至少一个业务 Pod 的 image 匹配 `ghcr.io/`  
3. Ingress health 200  

```bash
#!/usr/bin/env bash
set -euo pipefail
NS="${K8S_NAMESPACE:-iot-learn}"
APP="${ARGOCD_APP:-iot-learn-lab}"
NS_ARGO="${ARGOCD_NS:-argocd}"
HOST="${INGRESS_HOST:-device-report.iot-learn.local}"
echo "== K10: GitOps CD (GHCR) =="
SYNC=$(kubectl -n "$NS_ARGO" get application "$APP" -o jsonpath='{.status.sync.status}' 2>/dev/null || echo missing)
HEALTH=$(kubectl -n "$NS_ARGO" get application "$APP" -o jsonpath='{.status.health.status}' 2>/dev/null || echo missing)
echo "Application ${APP}: sync=${SYNC} health=${HEALTH}"
[[ "$SYNC" == "Synced" && "$HEALTH" == "Healthy" ]] || { echo "K10 FAIL: app not Synced/Healthy"; exit 1; }
IMG=$(kubectl -n "$NS" get pods -l app=device-report-service -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null || true)
echo "device-report-service image: ${IMG}"
echo "$IMG" | grep -q 'ghcr.io/' || { echo "K10 FAIL: expected ghcr.io image"; exit 1; }
CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: ${HOST}" "http://$(minikube ip)/actuator/health" || echo 000)
echo "Ingress health HTTP ${CODE}"
[[ "$CODE" == "200" ]] || { echo "K10 FAIL: health not 200"; exit 1; }
echo "K10 PASS: GHCR image in use; Ingress health OK"
```

- [ ] **Step 2: chmod +x 并试跑**

- [ ] **Step 3: 文档引用脚本（runbook）**

---

### Task 6: 续写 runbook + 面试笔记 + Spec

**Files:**

- Modify: `iot-learn-lab/docs/stage2-cicd-runbook.md`（补 CD 实操章：改 values、Secret、Sync、校验）  
- Modify: `iot-learn-lab/docs/stage2-interview-notes.md`（W10 场景）  
- Modify: `docs/superpowers/specs/2026-07-13-stage2-k8s-gitops-design.md`（W10 链接 + 变更记录）  
- Modify: `iot-learn-lab/README.md`（W10 勾选）

- [ ] **Step 1–3: 按上表更新文档**（实施时由执行者勾选）

- [ ] **Step 4: Commit** — **仅当你明确要求时再提交**（本规划会话可按用户要求跳过）

---

### Task 7:（加分）CI 自动开 PR 更新 image tag

**非主线。** 思路：`build-and-push` 成功后 job 用 bot token 改 values 并 `gh pr create`；合并 PR 即晋升。  
主线用 **手工改 SHA** 即可结业。

---

## W10 完成标准（Checklist）

- [ ] 三服务 Pod `image` 均为 `ghcr.io/<owner>/...:<sha>`  
- [ ] Argo Application Synced + Healthy  
- [ ] Ingress/health 冒烟通过  
- [ ] 主叙述不再依赖 `minikube image load`  
- [ ] `scenario-k10-*.sh` → `K10 PASS`  
- [ ] `stage2-cicd-runbook.md` 含 CD 章；interview notes 已更新  

---

## W10 面试话术速记

> 「CI 只负责构建并推送到 GHCR。上线是改 Git 里的镜像引用，Argo CD Sync 后集群拉取同一 SHA。这样构建一次、环境只是不同的部署目标；生产晋升是改 prod 期望，而不是再打包一次。」

---

## 排障

| 现象 | 处理 |
|------|------|
| ImagePullBackOff | 可见性 / Secret / tag 打错 / 网络 |
| Sync 后仍旧镜像 | valueFiles 覆盖顺序；Rollout 未更新；看实际渲染 |
| Argo 立刻改回 | auto-sync + Git 未改或改错分支 |
| 403 pull | PAT scope；Secret 未挂到 SA/Pod |

---

## Spec 覆盖映射

| Spec（W10） | 本计划 |
|-------------|--------|
| 更新 values image | Task 3 |
| push → 集群更新 | Task 4 |
| stage2-cicd-runbook | Task 6（续写） |
| 端到端验证 | Task 4–5 |

---

## 执行方式

计划已就绪。你说「开始 W10 Task 1」或「按计划改 values」即可继续实施（提交与否听你安排）。
