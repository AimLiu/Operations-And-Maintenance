# Stage 2 W7：Argo Rollouts 金丝雀 + Analysis abort Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 minikube 安装 **Argo Rollouts**，把 `device-report-service` 从 Deployment 演进为 `kind: Rollout`（canary steps 10%→50%→100%），用手工 abort 与（可选）Prometheus AnalysisTemplate 复现 Phase 4 C3「v2 bug → 5xx↑ → 回滚」，并跑通 `scenario-k7-rollouts-canary.sh`。

**Architecture:** Rollouts Controller 装在 `argo-rollouts` Namespace；Helm Chart 用开关把 `device-report` 渲染为 Rollout（其余两服务仍是 Deployment）。金丝雀由 **同一 Service 后的 stable/canary ReplicaSet + setWeight** 近似分流（不引入 Istio）。发布仍走 **Git → Argo CD Sync**；流量推进由 **Rollouts Controller** 执行。Prometheus 仍在 WSL Docker；Analysis 通过 `host.minikube.internal:9090` 查询 `version="v2"` 错误率。W7 **不做** Jaeger / CI 改 tag（W8–W10）。

**Tech Stack:** Argo Rollouts（stable）、现有 Helm Chart + Argo CD Application、kubectl-argo-rollouts 插件、外部 Prometheus、minikube Ingress

**Spec 来源:** `docs/superpowers/specs/2026-07-13-stage2-k8s-gitops-design.md`（W7 段）

**前置知识指南:** `docs/superpowers/guides/2026-07-22-stage2-w7-rollouts.md`

**前置条件（W6 已完成）：**

- [x] Argo CD Application `iot-learn-lab` 能 Synced / Healthy
- [x] Chart 三层 values；`values-v1` / `values-v2`（v2 + canary-bug）可用
- [x] Ingress / NodePort 可打到 `device-report-service`
- [x] W3 外部 Prometheus 能刮到 Pod 指标（或至少能用 curl 打出 5xx 人工判断）
- [ ] `kubectl argo rollouts` 插件可装（或全程用 `kubectl get rollout` + logs）

**时间预算:** 1 周 × 10–15h

**W7 边界:**

| W7 做 | W7 不做 |
|-------|---------|
| 安装 Argo Rollouts + Dashboard（可选） | Istio / Linkerd / APISIX 权重金丝雀 |
| `device-report` → `kind: Rollout` + canary steps | 改 dispatch / consumer 为 Rollout |
| 手工 `abort` / `promote`；可选 AnalysisTemplate | 蓝绿（blueGreen）主路径 |
| `scenario-k7-rollouts-canary.sh` | Jaeger（W8）；CI 推镜像（W9–W10） |
| 面试对照 Phase 4 APISIX vs Rollouts | 删除 Phase 4 脚本；删除 Deployment 对照能力（用 values 开关保留） |

---

## W7 拓扑（读完再动手）

```text
Git（values 从 v1 → v2+canary-bug）
        │
        ▼
Argo CD Sync  → 更新 Rollout Pod 模板（version/env）
        │
        ▼
Argo Rollouts Controller
  stable RS (v1) ────┐
                     ├──► Service device-report-service ──► Ingress / NodePort
  canary RS (v2) ────┘     setWeight 10 → 50 → 100
        │
        ├─ 人工：kubectl argo rollouts abort ...
        └─ 可选：AnalysisTemplate → Prometheus (host.minikube.internal:9090)
                 version="v2" 5xx 过高 → 自动 abort
```

**与 Phase 4 / W5 / W6 对照：**

| 以前 | W7 |
|------|-----|
| Phase 4：APISIX upstream 90/10 | Rollout `setWeight`（集群内发布控制器） |
| W5：整池切到 v2 values（无金丝雀流量） | **同一 Service 下** stable + canary 并存 |
| W6：Git → Sync 改副本/配置 | Sync 触发 **渐进式发布**，不是瞬间全切 |
| `helm rollback` / APISIX 回滚脚本 | `rollouts abort`（回到 stable）+ Git 改回 v1 |

---

## 文件结构（W7 新增 / 修改）

```text
iot-learn-lab/
├── infra/
│   ├── argocd/
│   │   └── application-iot-learn-lab.yaml   # 可选：ignoreDifferences（Rollout）
│   ├── rollouts/
│   │   ├── README.md                        # 安装、插件、与 Argo CD 共存注意
│   │   └── analysis-template-device-report.yaml  # 可选；也可放进 Helm templates
│   └── helm/iot-learn-lab/
│       ├── values.yaml                      # deviceReport.rollouts.* 开关与 steps
│       ├── values-v1.yaml / values-v2.yaml  # 保持语义；触发金丝雀仍靠改模板字段
│       └── templates/
│           ├── device-report-deployment.yaml      # rollouts.enabled=false 时渲染
│           ├── device-report-rollout.yaml         # NEW；enabled=true
│           └── analysis-template-*.yaml           # 可选 NEW
├── scripts/stage2/
│   └── scenario-k7-rollouts-canary.sh
└── docs/
    └── stage2-interview-notes.md            # 追加 W7

docs/superpowers/
├── plans/2026-07-22-stage2-w7-rollouts.md   # 本文件
├── guides/2026-07-22-stage2-w7-rollouts.md
└── specs/2026-07-13-stage2-k8s-gitops-design.md  # 链到 W7；Checklist 勾选说明
```

---

## 学习场景 K7：Rollouts 金丝雀 abort（W7 Day 5–6）

| 项 | 内容 |
|----|------|
| **操作** | 基线 v1 Healthy → 推送 v2+bug → canary 10% 出现 5xx → `abort` → 流量回 stable v1 |
| **预期** | `scenario-k7-rollouts-canary.sh` → `K7 PASS` |
| **加分** | AnalysisTemplate 在错误率超阈值时自动 abort（不强制阻塞结业） |
| **面试** | Deployment vs Rollout？APISIX 金丝雀 vs Rollouts？为何看 `version=v2` 而不是总错误率？abort 后 Git 还要不要改？ |

---

### Task 1: 安装 Argo Rollouts 与 kubectl 插件

**Files:**

- Create: `iot-learn-lab/infra/rollouts/README.md`

- [ ] **Step 1: 安装 Controller**

```bash
kubectl create namespace argo-rollouts
kubectl apply -n argo-rollouts -f \
  https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
kubectl -n argo-rollouts rollout status deploy/argo-rollouts --timeout=300s
kubectl -n argo-rollouts get pods
```

Expected: `argo-rollouts-*` Ready。

- [ ] **Step 2: 安装 kubectl 插件（WSL）**

按官方 Getting Started 安装 `kubectl-argo-rollouts`，验证：

```bash
kubectl argo rollouts version
```

若插件暂不可用：后续命令用 `kubectl get rollout -n iot-learn -o yaml` + Controller logs 代替，计划步骤仍以插件命令书写。

- [ ] **Step 3: 写 `infra/rollouts/README.md`**

至少包含：安装命令、插件、Dashboard 可选 port-forward、与 Argo CD「谁管什么」表、abort/promote 速查。

- [ ] **Step 4: Commit**

```bash
git add iot-learn-lab/infra/rollouts/README.md
git commit -m "$(cat <<'EOF'
docs(stage2-w7): add Argo Rollouts install notes

EOF
)"
```

---

### Task 2: Helm — Deployment / Rollout 开关

**Files:**

- Modify: `iot-learn-lab/infra/helm/iot-learn-lab/values.yaml`
- Modify: `iot-learn-lab/infra/helm/iot-learn-lab/templates/device-report-deployment.yaml`
- Create: `iot-learn-lab/infra/helm/iot-learn-lab/templates/device-report-rollout.yaml`

- [ ] **Step 1: 在 `values.yaml` 增加 rollouts 段（默认先 false，Task 3 再打开）**

```yaml
deviceReport:
  # ...existing...
  rollouts:
    enabled: false
    # canary 步进；学习环境用较长 pause，便于观察
    steps:
      - setWeight: 10
      - pause: { duration: 60s }
      - setWeight: 50
      - pause: { duration: 60s }
      - setWeight: 100
    # 可选：挂 Analysis（Task 5 打开）
    analysis:
      enabled: false
      templateName: device-report-error-rate
```

- [ ] **Step 2: Deployment 模板包条件**

仅在 `deviceReport.enabled` 且 **`not deviceReport.rollouts.enabled`** 时渲染现有 Deployment（保持 W4–W6 可回退）。

- [ ] **Step 3: 新增 `device-report-rollout.yaml`**

要点（与现网 Deployment 对齐）：

- `apiVersion: argoproj.io/v1alpha1` / `kind: Rollout`
- `metadata.name` / `selector` / Pod labels / checksum / probes / envFrom **与现 Deployment 一致**
- `spec.replicas` ← `deviceReport.replicaCount`
- `strategy.canary.steps` ← `toYaml .Values.deviceReport.rollouts.steps`
- **不要**同时留下同名 Deployment（开关互斥）

示意骨架：

```yaml
{{- if and .Values.deviceReport.enabled .Values.deviceReport.rollouts.enabled }}
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: {{ .Values.deviceReport.name }}
  namespace: {{ .Values.namespace }}
  labels:
    {{- include "iot-learn-lab.labels" . | nindent 4 }}
    app: {{ .Values.deviceReport.name }}
spec:
  replicas: {{ .Values.deviceReport.replicaCount }}
  revisionHistoryLimit: 3
  selector:
    matchLabels:
      app: {{ .Values.deviceReport.name }}
  template:
    metadata:
      labels:
        app: {{ .Values.deviceReport.name }}
        version: {{ .Values.deviceReport.versionLabel | quote }}
      annotations:
        checksum/config: {{ include (print $.Template.BasePath "/device-report-configmap.yaml") . | sha256sum }}
    spec:
      containers:
        - name: {{ .Values.deviceReport.name }}
          image: {{ .Values.deviceReport.image | quote }}
          # ... ports / envFrom / probes / resources 从 Deployment 原样搬迁 ...
  strategy:
    canary:
      steps:
        {{- toYaml .Values.deviceReport.rollouts.steps | nindent 8 }}
{{- end }}
```

- [ ] **Step 4: 本地渲染自检（不必装 Rollouts CRD 也能看 YAML）**

```bash
helm template iot-learn iot-learn-lab/infra/helm/iot-learn-lab \
  -f iot-learn-lab/infra/helm/iot-learn-lab/values.yaml \
  -f iot-learn-lab/infra/helm/iot-learn-lab/values-minikube.yaml \
  -f iot-learn-lab/infra/helm/iot-learn-lab/values-v1.yaml \
  --set deviceReport.rollouts.enabled=true \
  | grep -E 'kind: (Deployment|Rollout)' 
```

Expected: `device-report` 为 `Rollout`；dispatch/consumer 仍为 `Deployment`。

- [ ] **Step 5: Commit**

```bash
git add iot-learn-lab/infra/helm/iot-learn-lab/
git commit -m "$(cat <<'EOF'
feat(stage2-w7): add optional Rollout template for device-report

EOF
)"
```

---

### Task 3: 迁权 — 打开 Rollout 并由 Argo Sync

**Files:**

- Modify: `iot-learn-lab/infra/helm/iot-learn-lab/values-v1.yaml`（或 `values-minikube.yaml`）设 `deviceReport.rollouts.enabled: true`
- Modify（可选）: `iot-learn-lab/infra/argocd/application-iot-learn-lab.yaml` — `ignoreDifferences`

- [ ] **Step 1: values 打开开关并 push**

在 `values-v1.yaml`（Application 当前 valueFiles 末层）增加：

```yaml
deviceReport:
  # ...existing v1 fields...
  rollouts:
    enabled: true
```

`git commit && git push`（Argo 只读远程）。

- [ ] **Step 2: 处理同名 Deployment 冲突**

Sync 前若集群仍有 `Deployment/device-report-service`：

```bash
# 方案 A（推荐学习环境）：先删 Deployment，让 Rollout 接管同名工作负载与 Pod 标签
kubectl -n iot-learn delete deployment device-report-service --wait=true
```

然后 Argo Sync（UI 或 annotate refresh + sync）。**不要**让 Deployment 与 Rollout 长期并存争抢同一 `app=` selector。

- [ ] **Step 3: 确认 Rollout Healthy**

```bash
kubectl -n iot-learn get rollout device-report-service
kubectl argo rollouts get rollout device-report-service -n iot-learn
kubectl -n iot-learn get pods -l app=device-report-service
curl -sf -H "Host: device-report.iot-learn.local" http://$(minikube ip)/actuator/health
```

Expected: Rollout Healthy；Ingress health 仍 OK。

- [ ] **Step 4（可选）: Argo CD ignoreDifferences**

若 Self-heal 与 canary 过程中的 replicas/status 打架，在 Application 增加对 `Rollout` 的 `ignoreDifferences`（如 `/status` 或文档推荐字段），再 apply Application。以「能完成一次 canary + abort」为准，不要过度调参。

- [ ] **Step 5: Commit + push Application/values 变更**

---

### Task 4: 手工金丝雀 — promote / abort

**Files:** 无强制代码；操作记录写入 interview notes（Task 7）

- [ ] **Step 1: 观察当前 stable**

```bash
kubectl argo rollouts get rollout device-report-service -n iot-learn
```

记下当前 `version` label / ConfigMap 为 v1、`canaryBugEnabled=false`。

- [ ] **Step 2: 触发一次「无 bug」模板变更（热身）**

任选其一（优先 GitOps）：

- 仅改一个无害字段（如 `replicaCount` 或注释性 ConfigMap 值）并 Sync；或  
- 临时把 `appVersion` 改成 `v1-canary-drill` 再改回  

学会读：

```bash
kubectl argo rollouts get rollout device-report-service -n iot-learn --watch
```

在 pause 步骤可：

```bash
kubectl argo rollouts promote device-report-service -n iot-learn
# 或等到 duration 自动继续
```

- [ ] **Step 3: 真正的 C3 路径 — 切到 values-v2 语义**

把 Application 的 `valueFiles` **临时**改为包含 `values-v2.yaml`（替换或追加在 v1 之后），或直接把 v2 字段合并进跟踪中的 values 并 push：

- `versionLabel/appVersion: v2`
- `canaryBugEnabled: true`

Sync 后 canary Pod 应带 `version=v2` 且易 5xx。

- [ ] **Step 4: 打流观察**

```bash
# 示例：循环打 Ingress（Host 头按你的 values）
for i in $(seq 1 30); do
  curl -s -o /dev/null -w "%{http_code}\n" \
    -H "Host: device-report.iot-learn.local" \
    -X POST "http://$(minikube ip)/api/reports" \
    -H "Content-Type: application/json" \
    -d '{"deviceId":"k7-demo","payload":"x"}' || true
  sleep 0.3
done
```

Expected: 金丝雀权重阶段出现 **部分** 5xx（不是 100%），对标 Phase 4「总错误率被稀释」。

- [ ] **Step 5: abort 回 stable**

```bash
kubectl argo rollouts abort device-report-service -n iot-learn
kubectl argo rollouts get rollout device-report-service -n iot-learn
```

Expected: 回到上一稳定版本 Pod；5xx 消失或显著下降。

- [ ] **Step 6: Git 与集群对齐**

abort **只修集群进度**，Git 若仍是 v2+bug，Argo Self-heal/下次 Sync 可能再次发起发布。结业要求：

1. abort 验证成功  
2. **把 Git 改回 v1（或去掉 values-v2）并 Sync**，Application 回到 Synced + Healthy  

---

### Task 5（加分）: AnalysisTemplate + Prometheus

**Files:**

- Create: `iot-learn-lab/infra/helm/iot-learn-lab/templates/analysis-template-device-report.yaml`  
  或 `iot-learn-lab/infra/rollouts/analysis-template-device-report.yaml`
- Modify: `values.yaml` → `deviceReport.rollouts.analysis.enabled: true` 并在 canary steps 中 `analysis` 引用

- [ ] **Step 1: 确认 Prometheus 从 Pod 网可达**

```bash
kubectl -n iot-learn run curl-prom --rm -it --image=curlimages/curl --restart=Never -- \
  curl -sS "http://host.minikube.internal:9090/-/ready"
```

Expected: ready。若不通，先修 W3 网络，不要硬开 Analysis。

- [ ] **Step 2: 编写 AnalysisTemplate**

使用 prometheus provider，`address: http://host.minikube.internal:9090`，查询需带 **`version="v2"`**（具体 metric 名以你们 `/actuator/prometheus` 与 Grafana 面板为准，常见为 `http_server_requests_seconds_count` 的 5xx ratio）。阈值示例：错误率 `> 0.05` 失败 → Rollouts abort。

- [ ] **Step 3: 在 canary steps 早期挂 analysis**（如 weight 10 后）

- [ ] **Step 4: 再跑一次 v2+bug，期望自动 abort**

- [ ] **Step 5: Commit**

若本周时间不够：**可跳过 Task 5**，面试口述「AnalysisRun 用 Prometheus 按 version 判定」即可，Checklist 标可选。

---

### Task 6: 场景脚本 K7

**Files:**

- Create: `iot-learn-lab/scripts/stage2/scenario-k7-rollouts-canary.sh`
- Modify: `iot-learn-lab/docs/stage2-helm-cheatsheet.md`（追加 Rollouts 三行速查）

- [ ] **Step 1: 脚本最小断言**

建议检查：

1. `Rollout` 存在且（结束态）Healthy / Degraded 符合阶段  
2. Ingress 或 NodePort health 可访问  
3. 文档化「触发 canary / abort」步骤（脚本可半自动：检测 canary-bug 开启时出现非 2xx，再提示执行 abort，或调用 `kubectl argo rollouts abort` 后验证恢复）

脚本头注释写清：**依赖 Rollouts enabled + 插件可选**。

- [ ] **Step 2: 跑通**

```bash
chmod +x iot-learn-lab/scripts/stage2/scenario-k7-rollouts-canary.sh
./iot-learn-lab/scripts/stage2/scenario-k7-rollouts-canary.sh
```

Expected: `K7 PASS: ...`

- [ ] **Step 3: Commit**

```bash
git add iot-learn-lab/scripts/stage2/scenario-k7-rollouts-canary.sh \
        iot-learn-lab/docs/stage2-helm-cheatsheet.md
git commit -m "$(cat <<'EOF'
feat(stage2-w7): add K7 rollouts canary scenario script

EOF
)"
```

---

### Task 7: 文档收尾

**Files:**

- Modify: `iot-learn-lab/docs/stage2-interview-notes.md`
- Modify: `iot-learn-lab/README.md`（进度表 W7）
- Modify: `docs/superpowers/specs/2026-07-13-stage2-k8s-gitops-design.md`（链接 + 变更记录；成功标准勾选说明）

- [ ] **Step 1: interview notes 追加 W7**

场景表：手工 canary、abort、（可选）Analysis。  
面试题：Deployment vs Rollout；APISIX vs Rollouts；为何按 version 看错误率；abort 后为何还要改 Git。

- [ ] **Step 2: README 进度**

W7：进行中 → 完成（执行后勾）。

- [ ] **Step 3: Spec 变更记录**

增加：`2026-07-22 | 补充 W7 Rollouts 计划与指南；场景脚本 k7`。

- [ ] **Step 4: Commit + push**（保证 Argo 与文档一致）

---

## W7 完成标准（Checklist）

- [ ] `argo-rollouts` Controller Ready；能 `kubectl argo rollouts get`（或等价 kubectl）
- [ ] `device-report` 由 **Rollout** 管理；dispatch/consumer 仍为 Deployment
- [ ] 完成一次 canary：v2+bug → 观察到部分 5xx → **abort** → 恢复
- [ ] Git 最终回到 v1（或非 bug）且 Argo Application Synced/Healthy
- [ ] `scenario-k7-rollouts-canary.sh` → `K7 PASS`
- [ ] （可选）AnalysisTemplate 自动 abort
- [ ] interview notes / README / rollouts README 已更新

---

## W7 面试话术速记

> 「应用发布用 Argo Rollouts 把 Deployment 换成 Rollout，用 canary steps 按权重放量；入口层金丝雀（APISIX）切的是网关 upstream，Rollouts 切的是工作负载 ReplicaSet。观测必须按 `version=v2` 看错误率，否则会被稳定版本稀释。abort 回到上一个 stable；在 GitOps 下还要把 Git 期望状态改回，否则下次 Sync 会再发一版。」

---

## 常见坑

| 现象 | 可能原因 | 处理 |
|------|----------|------|
| Sync 后 Deployment + Rollout 并存 | 开关未互斥或旧 Deployment 未删 | 删 Deployment；确认 template 条件 |
| scale/abort 被 Self-heal 拉回 | Argo 与 Rollouts 争 | ignoreDifferences；canary 期间慎用强制 Sync |
| setWeight 但几乎全是新版本流量 | 副本太少（如 replicas=1）权重近似失真 | 学习环境 `replicaCount>=2` |
| Analysis 一直 Pending | Prometheus 地址不通 / 指标名不对 | 先 curl Prom；对齐 metric label |
| abort 后又自动金丝雀 | Git 仍是 v2 | 改回 values-v1 并 Sync |
| ImagePullBackOff on canary | 与 W1 相同，minikube 镜像缓存 | `minikube image load` |

---

## 下一步（W8 预告）

- Micrometer Tracing + OTLP → Jaeger  
- `POST /reports` 全链路（Feign + Kafka consumer span）  
- 产出 `docs/stage2-tracing-runbook.md`

**W8 实施计划：** `docs/superpowers/plans/2026-07-23-stage2-w8-jaeger.md`  
**W8 前置指南：** `docs/superpowers/guides/2026-07-23-stage2-w8-jaeger.md`

---

## Spec 覆盖自检

| Spec 要求（Stage 2 W7 段） | 本计划 Task |
|---------------------------|-------------|
| 安装 / 理解 Rollout 替代 Deployment | Task 1–2 |
| canary 10% → 50% → 100% | Task 2 steps + Task 4 |
| 复现 Phase 4 C3：v2 bug → abort | Task 4 |
| AnalysisTemplate version=v2 错误率 | Task 5（加分） |
| 产出 `scenario-k7-rollouts-canary.sh` | Task 6 |

---

## 执行方式

**Plan complete and saved to `docs/superpowers/plans/2026-07-22-stage2-w7-rollouts.md`. Two execution options:**

1. **Subagent-Driven（推荐）** — 按 Task 派发子代理，每 Task 后 review  
2. **Inline Execution** — 本会话按 Task 1→7 连续执行；Checkpoint 建议在 Task 3（Rollout Healthy）与 Task 4（abort 成功）后  

**Which approach?**
