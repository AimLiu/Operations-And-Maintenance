# Stage 2 W5：多环境 Values + ConfigMap checksum + canary-bug 切换 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 W4 Chart 上完成 **配置外置加深**：中间件地址收敛到可叠加的 env values；Deployment 增加 **ConfigMap checksum**（改 ConfigMap 自动滚 Pod）；**一条 Helm 命令**切换 `device-report` 到 v2（`version` label + `app.canary-bug-enabled=true`）并验证故障注入，再切回 v1；产出 `stage2-helm-cheatsheet.md`。

**Architecture:** 继续单 Chart。`values.yaml` 保留结构默认值；新增 `values-minikube.yaml` 专放混合中间件地址（多环境入口）。ConfigMap 增加 `APP_VERSION` / `APP_CANARY_BUG_ENABLED`（Spring 松散绑定到 `app.*`）。三服务 Deployment 的 Pod 模板注解写入对应 ConfigMap 的 `sha256sum`，使 `helm upgrade` 变更 ConfigMap 时触发滚动。W5 **不做** Argo CD / Rollouts / 真双 Deployment 金丝雀流量分割（W6–W7）。

**Tech Stack:** Helm 3、现有 Chart `infra/helm/iot-learn-lab`、Spring Boot `app.canary-bug-enabled`（Phase 4）、minikube

**Spec 来源:** `docs/superpowers/specs/2026-07-13-stage2-k8s-gitops-design.md`（W5 段）

**前置知识指南:** `docs/superpowers/guides/2026-07-19-stage2-w5-helm-values.md`

**前置条件（W4 已完成）：**

- [x] `helm upgrade --install iot-learn ...` 可用；三服务 Ready
- [x] `values.yaml` / `values-v1.yaml` / `values-v2.yaml` + `templates/*` 齐全
- [x] `scenario-k4-helm-baseline.sh` 可 `K4 PASS`；K2/K3 冒烟仍可通过
- [ ] 本计划会改 `application-k8s.yml` → 需 **rebuild + minikube image load** report 镜像

**时间预算:** 1 周 × 10–15h

**W5 边界:**

| W5 做 | W5 不做 |
|-------|---------|
| `values-minikube.yaml` + values 分层约定 | 子 Chart |
| ConfigMap 注入 canary / version；checksum 自动滚更 | Nacos 热更新 canary（k8s profile 仍关 Nacos） |
| 一条命令切 v2+bug / 切回 v1 | APISIX 流量分割、Argo Rollouts（W7） |
| `scenario-k5-helm-values-switch.sh` | 真·第二套 v2 Deployment 并行 |
| `docs/stage2-helm-cheatsheet.md` | Argo CD Application（W6） |

---

## W5 拓扑（读完再动手）

```text
-f values.yaml
-f values-minikube.yaml     ← 中间件地址（环境层）
-f values-v1.yaml | values-v2.yaml   ← 版本层（label / canary-bug）
        │
        ▼ helm upgrade --install
ConfigMap (含 APP_VERSION / APP_CANARY_BUG_ENABLED / DB_*)
        │  checksum 注解挂在 Pod template
        ▼
Deployment 滚动 → 新 Pod 读到新 env
```

**一条命令切 v2（目标体验）：**

```bash
helm upgrade iot-learn infra/helm/iot-learn-lab -n iot-learn \
  -f values.yaml -f values-minikube.yaml -f values-v2.yaml --wait
```

---

## 文件结构（W5 新增 / 修改）

```text
iot-learn-lab/
├── device-report-service/src/main/resources/
│   └── application-k8s.yml              # 修改：显式绑定 APP_* → app.*
├── infra/helm/iot-learn-lab/
│   ├── values.yaml                      # 追加 canaryBugEnabled / appVersion 默认
│   ├── values-minikube.yaml             # 新建：middleware 环境层
│   ├── values-v1.yaml                   # 明确 canary=false
│   ├── values-v2.yaml                   # canary=true + version=v2
│   └── templates/
│       ├── device-report-configmap.yaml
│       ├── device-report-deployment.yaml    # checksum 注解
│       ├── command-dispatch-deployment.yaml
│       ├── device-report-consumer-configmap.yaml
│       └── device-report-consumer-deployment.yaml
├── scripts/stage2/
│   └── scenario-k5-helm-values-switch.sh
└── docs/
    ├── stage2-helm-cheatsheet.md            # 新建
    └── stage2-interview-notes.md            # 追加 W5

docs/superpowers/
├── plans/2026-07-19-stage2-w5-helm-values.md    # 本文件
└── guides/2026-07-19-stage2-w5-helm-values.md
```

---

## 学习场景 K5：Values 切换 + checksum（W5 Day 5–6）

| 项 | 内容 |
|----|------|
| **操作** | 切 v2+canary → 上报出现 5xx → 切回 v1；改 middleware 验证 Pod 自动滚动 |
| **预期** | 一条 helm 命令完成切换；无需手工 `rollout restart`；K5 PASS |
| **面试** | Helm vs Kustomize？checksum 解决什么？为何 k8s 不用 Nacos 热更 canary？ |

---

### Task 1: 应用侧支持环境变量驱动 canary / version

**Files:**
- Modify: `iot-learn-lab/device-report-service/src/main/resources/application-k8s.yml`

> Spring 虽可用松散绑定 `APP_CANARY_BUG_ENABLED` → `app.canary-bug-enabled`，W5 在 k8s profile **显式写出**，避免「隐式魔法」难排查。

- [ ] **Step 1: 在 `application-k8s.yml` 末尾追加**

```yaml
# W5：由 ConfigMap 注入；勿依赖 Nacos 热更新（k8s profile 下 config 仍关闭）
app:
  version: ${APP_VERSION:v1}
  canary-bug-enabled: ${APP_CANARY_BUG_ENABLED:false}
```

- [ ] **Step 2: 重建并 load report 镜像**

```bash
cd iot-learn-lab
mvn -B -pl device-report-service -am package -DskipTests
docker build -f device-report-service/Dockerfile -t device-report-service:0.1.0-SNAPSHOT .
minikube image rm device-report-service:0.1.0-SNAPSHOT || true
minikube image load device-report-service:0.1.0-SNAPSHOT
```

Expected: load 成功（若 Pod 占用镜像，先 `kubectl scale deploy/device-report-service -n iot-learn --replicas=0` 再 rm/load，完成后 scale 回 1 或交给后续 helm upgrade）

---

### Task 2: Values 分层——`values-minikube` + canary 字段

**Files:**
- Modify: `iot-learn-lab/infra/helm/iot-learn-lab/values.yaml`
- Create: `iot-learn-lab/infra/helm/iot-learn-lab/values-minikube.yaml`
- Modify: `iot-learn-lab/infra/helm/iot-learn-lab/values-v1.yaml`
- Modify: `iot-learn-lab/infra/helm/iot-learn-lab/values-v2.yaml`

- [ ] **Step 1: 在 `values.yaml` 的 `deviceReport` 下追加默认字段**

```yaml
  # W5：写入 ConfigMap → 环境变量
  appVersion: v1
  canaryBugEnabled: false
```

（放在 `dispatchBaseUrl` 附近即可。）

- [ ] **Step 2: 创建 `values-minikube.yaml`（环境层：只放中间件）**

```yaml
# 环境层：混合中间件地址。改这里即可全域生效（经 ConfigMap）。
# 用法：-f values.yaml -f values-minikube.yaml -f values-v1.yaml
middleware:
  dbHost: host.minikube.internal
  dbPort: "5432"
  dbUsername: postgres
  dbPassword: postgres
  redisHost: host.minikube.internal
  redisPort: "6379"
  nacosAddr: "192.168.19.64:8848"
  sentinelDashboard: host.minikube.internal:8858
  kafkaBootstrap: host.minikube.internal:9092
  kafkaTopic: device-report-events
  kafkaConsumerGroupId: device-report-consumer-group-k8s
```

> `values.yaml` 里可保留同名 `middleware` 作默认；叠加 `values-minikube.yaml` 后以环境文件为准。以后若有 `values-ci.yaml`，只换这一层。

- [ ] **Step 3: 更新 `values-v1.yaml`**

```yaml
deviceReport:
  versionLabel: v1
  appVersion: v1
  canaryBugEnabled: false
  image: device-report-service:0.1.0-SNAPSHOT
commandDispatch:
  versionLabel: v1
deviceReportConsumer:
  versionLabel: v1
```

- [ ] **Step 4: 更新 `values-v2.yaml`**

```yaml
# 版本层：一条命令切到「带 version=v2 + canary-bug」的 report
deviceReport:
  versionLabel: v2
  appVersion: v2
  canaryBugEnabled: true
  image: device-report-service:0.1.0-SNAPSHOT
  replicaCount: 1
commandDispatch:
  versionLabel: v1
deviceReportConsumer:
  versionLabel: v1
```

---

### Task 3: ConfigMap 注入 APP_* 字段

**Files:**
- Modify: `iot-learn-lab/infra/helm/iot-learn-lab/templates/device-report-configmap.yaml`

- [ ] **Step 1: 在 ConfigMap `data:` 末尾追加**

```yaml
  APP_VERSION: {{ .Values.deviceReport.appVersion | quote }}
  APP_CANARY_BUG_ENABLED: {{ .Values.deviceReport.canaryBugEnabled | quote }}
```

完整 `data` 段应类似：

```yaml
data:
  DB_HOST: {{ .Values.middleware.dbHost | quote }}
  DB_PORT: {{ .Values.middleware.dbPort | quote }}
  DB_USERNAME: {{ .Values.middleware.dbUsername | quote }}
  DB_PASSWORD: {{ .Values.middleware.dbPassword | quote }}
  REDIS_HOST: {{ .Values.middleware.redisHost | quote }}
  REDIS_PORT: {{ .Values.middleware.redisPort | quote }}
  NACOS_ADDR: {{ .Values.middleware.nacosAddr | quote }}
  SENTINEL_DASHBOARD: {{ .Values.middleware.sentinelDashboard | quote }}
  SPRING_PROFILES_ACTIVE: {{ .Values.global.springProfilesActive | quote }}
  DISPATCH_BASE_URL: {{ .Values.deviceReport.dispatchBaseUrl | quote }}
  KAFKA_BOOTSTRAP: {{ .Values.middleware.kafkaBootstrap | quote }}
  APP_VERSION: {{ .Values.deviceReport.appVersion | quote }}
  APP_CANARY_BUG_ENABLED: {{ .Values.deviceReport.canaryBugEnabled | quote }}
```

- [ ] **Step 2: 渲染确认**

```bash
helm template iot-learn infra/helm/iot-learn-lab \
  -n iot-learn \
  -f infra/helm/iot-learn-lab/values.yaml \
  -f infra/helm/iot-learn-lab/values-minikube.yaml \
  -f infra/helm/iot-learn-lab/values-v2.yaml \
  | grep -A2 APP_CANARY
```

Expected: `APP_CANARY_BUG_ENABLED: "true"`（或 `true` 的 quote 形式）

---

### Task 4: Deployment 增加 ConfigMap checksum 注解

**Files:**
- Modify: `iot-learn-lab/infra/helm/iot-learn-lab/templates/device-report-deployment.yaml`
- Modify: `iot-learn-lab/infra/helm/iot-learn-lab/templates/command-dispatch-deployment.yaml`
- Modify: `iot-learn-lab/infra/helm/iot-learn-lab/templates/device-report-consumer-deployment.yaml`

> 原理：把 ConfigMap 内容的哈希写进 **Pod template** 的 annotation。ConfigMap 一变 → 哈希变 → Pod 模板变 → Deployment 自动滚动。

- [ ] **Step 1: 修改 `device-report-deployment.yaml` 的 `template.metadata`**

将：

```yaml
    metadata:
      labels:
        app: {{ .Values.deviceReport.name }}
        version: {{ .Values.deviceReport.versionLabel | quote }}
```

改为：

```yaml
    metadata:
      labels:
        app: {{ .Values.deviceReport.name }}
        version: {{ .Values.deviceReport.versionLabel | quote }}
      annotations:
        checksum/config: {{ include (print $.Template.BasePath "/device-report-configmap.yaml") . | sha256sum }}
```

- [ ] **Step 2: `command-dispatch-deployment.yaml` 同样在 `template.metadata` 下加**

```yaml
      annotations:
        checksum/config: {{ include (print $.Template.BasePath "/command-dispatch-configmap.yaml") . | sha256sum }}
```

（保留原有 `labels`。）

- [ ] **Step 3: `device-report-consumer-deployment.yaml` 同样加**

```yaml
      annotations:
        checksum/config: {{ include (print $.Template.BasePath "/device-report-consumer-configmap.yaml") . | sha256sum }}
```

- [ ] **Step 4: lint + 安装（三层 values）**

```bash
cd iot-learn-lab
helm lint infra/helm/iot-learn-lab
helm upgrade --install iot-learn infra/helm/iot-learn-lab \
  -n iot-learn \
  -f infra/helm/iot-learn-lab/values.yaml \
  -f infra/helm/iot-learn-lab/values-minikube.yaml \
  -f infra/helm/iot-learn-lab/values-v1.yaml \
  --wait --timeout 5m

kubectl get pods -n iot-learn -o wide
kubectl get cm device-report-middleware -n iot-learn -o yaml | grep -E 'APP_|DB_HOST'
```

Expected: 三 Pod Ready；ConfigMap 含 `APP_VERSION: v1`、`APP_CANARY_BUG_ENABLED: "false"`

---

### Task 5: 验证 checksum——改中间件触发自动滚动

**Files:**（临时改 `values-minikube.yaml` 或 `--set`）

- [ ] **Step 1: 记录当前 Pod 名**

```bash
OLD_POD=$(kubectl get pod -n iot-learn -l app=device-report-service -o jsonpath='{.items[0].metadata.name}')
echo "OLD_POD=$OLD_POD"
```

- [ ] **Step 2: 用无害变更触发 ConfigMap 变化（示例：改 sentinel 地址字符串再改回）**

```bash
# 故意改一个仍可达或仅影响 Sentinel 连接的值，观察滚动
helm upgrade iot-learn infra/helm/iot-learn-lab \
  -n iot-learn \
  -f infra/helm/iot-learn-lab/values.yaml \
  -f infra/helm/iot-learn-lab/values-minikube.yaml \
  -f infra/helm/iot-learn-lab/values-v1.yaml \
  --set middleware.sentinelDashboard=host.minikube.internal:8858 \
  --set middleware.nacosAddr=192.168.19.64:8848 \
  --wait --timeout 5m

# 更直观：在 values-minikube.yaml 给 kafkaConsumerGroupId 加后缀 -w5test 再 upgrade，验证后改回
```

或直接编辑 `values-minikube.yaml` 把 `kafkaConsumerGroupId` 改为 `device-report-consumer-group-k8s-w5` 后：

```bash
helm upgrade iot-learn infra/helm/iot-learn-lab \
  -n iot-learn \
  -f infra/helm/iot-learn-lab/values.yaml \
  -f infra/helm/iot-learn-lab/values-minikube.yaml \
  -f infra/helm/iot-learn-lab/values-v1.yaml \
  --wait --timeout 5m

NEW_POD=$(kubectl get pod -n iot-learn -l app=device-report-service -o jsonpath='{.items[0].metadata.name}')
echo "NEW_POD=$NEW_POD"
test "$OLD_POD" != "$NEW_POD" && echo "CHECKSUM_ROLL_OK" || echo "CHECKSUM_ROLL_FAIL"
```

Expected: `CHECKSUM_ROLL_OK`（Pod 名变化）；**无需**手工 `rollout restart`

- [ ] **Step 3: 把 `kafkaConsumerGroupId` 改回 `device-report-consumer-group-k8s` 并再 upgrade 一次**（保持学习环境干净）

---

### Task 6: 一条命令切 v2 + canary-bug，再切回

**Files:**
- Create: `iot-learn-lab/scripts/stage2/scenario-k5-helm-values-switch.sh`

- [ ] **Step 1: 切到 v2**

```bash
helm upgrade iot-learn infra/helm/iot-learn-lab \
  -n iot-learn \
  -f infra/helm/iot-learn-lab/values.yaml \
  -f infra/helm/iot-learn-lab/values-minikube.yaml \
  -f infra/helm/iot-learn-lab/values-v2.yaml \
  --wait --timeout 5m

kubectl get pods -n iot-learn -l app=device-report-service --show-labels | grep version
kubectl get cm device-report-middleware -n iot-learn -o yaml | grep APP_
```

Expected: `version=v2`；`APP_CANARY_BUG_ENABLED` 为 true

- [ ] **Step 2: 验证 canary-bug（同步上报应失败/5xx）**

```bash
MINIKUBE_IP=$(minikube ip)
# 多打几次；canary-bug 在 maybeFail 时抛错 → 通常 500
for i in 1 2 3 4 5; do
  code=$(curl -s -o /tmp/k5-body.txt -w "%{http_code}" -H "Host: device-report.iot-learn.local" \
    -X POST "http://${MINIKUBE_IP}/api/v1/devices/k5-bug-${i}/reports" \
    -H "Content-Type: application/json" \
    -d "{\"payload\":{\"temp\":1,\"source\":\"k5\"}}")
  echo "attempt=$i http=$code"
done
```

Expected: 至少部分（或全部，取决于实现是否每次 fail）出现 **5xx**；日志可见 `canary-bug-simulated`

> 若 `CanaryBugConfig.maybeFail()` 为「开启即每次失败」，则应稳定 5xx。以你仓库实现为准。

- [ ] **Step 3: 切回 v1**

```bash
helm upgrade iot-learn infra/helm/iot-learn-lab \
  -n iot-learn \
  -f infra/helm/iot-learn-lab/values.yaml \
  -f infra/helm/iot-learn-lab/values-minikube.yaml \
  -f infra/helm/iot-learn-lab/values-v1.yaml \
  --wait --timeout 5m

curl -sf -H "Host: device-report.iot-learn.local" \
  -X POST "http://$(minikube ip)/api/v1/devices/k5-ok/reports" \
  -H "Content-Type: application/json" \
  -d "{\"payload\":{\"temp\":2,\"source\":\"k5-ok\"}}"
```

Expected: 201 风格成功 JSON

- [ ] **Step 4: 写入 `scenario-k5-helm-values-switch.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "${SCRIPT_DIR}/env.sh"

ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CHART="${ROOT}/infra/helm/iot-learn-lab"
NS="${K8S_NAMESPACE}"
REL="${HELM_RELEASE:-iot-learn}"
HOST="${INGRESS_HOST}"

echo "== K5: Helm values switch (v1 → v2+canary → v1) =="

helm upgrade "$REL" "$CHART" -n "$NS" \
  -f "${CHART}/values.yaml" \
  -f "${CHART}/values-minikube.yaml" \
  -f "${CHART}/values-v2.yaml" \
  --wait --timeout 5m

echo "-- expect canary 5xx --"
FAILS=0
for i in 1 2 3 4 5; do
  code=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: ${HOST}" \
    -X POST "http://${MINIKUBE_IP}/api/v1/devices/k5-bug-${i}/reports" \
    -H "Content-Type: application/json" \
    -d "{\"payload\":{\"temp\":1,\"source\":\"k5\"}}" || true)
  echo "attempt=$i http=$code"
  [[ "$code" =~ ^5 ]] && FAILS=$((FAILS+1))
done
[[ "$FAILS" -ge 1 ]] || { echo "K5 FAIL: expected at least one 5xx under canary-bug"; exit 1; }

helm upgrade "$REL" "$CHART" -n "$NS" \
  -f "${CHART}/values.yaml" \
  -f "${CHART}/values-minikube.yaml" \
  -f "${CHART}/values-v1.yaml" \
  --wait --timeout 5m

curl -sf -H "Host: ${HOST}" \
  -X POST "http://${MINIKUBE_IP}/api/v1/devices/k5-ok-$(date +%s)/reports" \
  -H "Content-Type: application/json" \
  -d "{\"payload\":{\"temp\":2,\"source\":\"k5-ok\"}}"
echo

echo "K5 PASS: v2+canary produced 5xx; v1 restored"
```

```bash
chmod +x iot-learn-lab/scripts/stage2/scenario-k5-helm-values-switch.sh
iot-learn-lab/scripts/stage2/scenario-k5-helm-values-switch.sh
```

Expected: `K5 PASS`

---

### Task 7: Cheatsheet + README + 面试笔记

**Files:**
- Create: `iot-learn-lab/docs/stage2-helm-cheatsheet.md`
- Modify: `iot-learn-lab/infra/k8s/README.md`（或 helm 旁加一句指向 cheatsheet）
- Modify: `iot-learn-lab/docs/stage2-interview-notes.md`
- Modify: `iot-learn-lab/README.md`（脚本表增加 k5）

- [ ] **Step 1: 写入 `stage2-helm-cheatsheet.md`**

```markdown
# Stage 2 Helm 速查

## 标准安装（三层 values）

\`\`\`bash
helm upgrade --install iot-learn infra/helm/iot-learn-lab -n iot-learn \
  -f infra/helm/iot-learn-lab/values.yaml \
  -f infra/helm/iot-learn-lab/values-minikube.yaml \
  -f infra/helm/iot-learn-lab/values-v1.yaml \
  --wait
\`\`\`

## 切 v2 + canary-bug / 切回

\`\`\`bash
# v2
helm upgrade iot-learn infra/helm/iot-learn-lab -n iot-learn \
  -f values.yaml -f values-minikube.yaml -f values-v2.yaml --wait

# v1
helm upgrade iot-learn infra/helm/iot-learn-lab -n iot-learn \
  -f values.yaml -f values-minikube.yaml -f values-v1.yaml --wait
\`\`\`

## 常用命令

| 命令 | 用途 |
|------|------|
| \`helm template ...\` | 只渲染不安装 |
| \`helm lint\` | 静态检查 |
| \`helm history\` | revision |
| \`helm rollback iot-learn N\` | 回滚 |
| \`helm get values iot-learn -n iot-learn\` | 看合并后 values |

## Values 分层口诀

1. \`values.yaml\` — 结构与默认
2. \`values-minikube.yaml\` — **环境**（中间件）
3. \`values-v1/v2.yaml\` — **版本**（label / canary）

后写的 \`-f\` 覆盖先写的。

## ConfigMap 与 checksum

- 改 middleware / APP_* → ConfigMap 变 → checksum 变 → **自动滚 Pod**
- 没有 checksum 时：对象更新了，旧容器 env 仍旧 → 需 \`rollout restart\`

## Helm vs Kustomize（面试一句）

| | Helm | Kustomize |
|--|------|-----------|
| 模型 | 模板 + values 包管理 | 无模板，base + overlay 补丁 |
| 生命周期 | Release / rollback 一等公民 | 偏 \`kubectl apply -k\` |
| 本仓库 | Stage 2 主线 | 了解即可，W5 不迁移 |

## 场景脚本

- K4：\`scenario-k4-helm-baseline.sh\`
- K5：\`scenario-k5-helm-values-switch.sh\`
```

- [ ] **Step 2: 面试笔记追加 W5 场景表 + 题目骨架**（执行后填初答/精炼）

至少覆盖：Helm vs Kustomize；checksum；一条命令切 v2；为何不用 Nacos 热更 canary；values 三层顺序。

- [ ] **Step 3: `infra/k8s/README.md` 增加 W5 短节**（指向 Helm 标准三层 `-f` 与 cheatsheet）

---

## W5 完成标准（Checklist）

- [ ] `application-k8s.yml` 含 `app.version` / `app.canary-bug-enabled` 环境变量绑定；镜像已 rebuild+load
- [ ] 存在 `values-minikube.yaml`；v1/v2 values 含 `canaryBugEnabled` / `appVersion`
- [ ] report ConfigMap 含 `APP_VERSION`、`APP_CANARY_BUG_ENABLED`
- [ ] 三服务 Deployment 均有 `checksum/config` 注解；改 ConfigMap 会自动滚 Pod
- [ ] 一条 `helm upgrade ... -f values-v2.yaml` 可打出 canary 5xx；`-f values-v1.yaml` 恢复
- [ ] `scenario-k5-helm-values-switch.sh` → `K5 PASS`
- [ ] `docs/stage2-helm-cheatsheet.md` 已写
- [ ] `stage2-interview-notes.md` 有 W5 章节

---

## W5 面试话术速记

| 问题 | 答法 |
|------|------|
| Helm vs Kustomize？ | Helm=模板+包+Release 历史；Kustomize=无模板叠加 patch；我们用 Helm 管多服务生命周期 |
| checksum？ | 把 ConfigMap 哈希打进 Pod 模板，配置变 → 自动滚动，解决 env 不热更新 |
| 一条命令切 v2？ | `-f values-v2.yaml` 覆盖 version/canary；不必改 Java 代码 |
| 为何不用 Nacos 热更？ | k8s profile 关 Nacos；用 ConfigMap+滚更更贴「不可变配置」叙事 |
| 和 Phase 4 关系？ | 同一 `canary-bug`；发现/配置从 Nacos 换成 Helm values |

---

## 常见踩坑

| 现象 | 原因 | 处理 |
|------|------|------|
| 切 v2 仍无 5xx | 镜像未 rebuild / APP_* 未进 ConfigMap / 旧 Pod 未滚 | 查 cm + pod 环境变量；确认 checksum |
| `canaryBugEnabled: true` 渲染成非布尔字符串异常 | quote 导致 Spring 解析问题 | 确认环境变量为 `true`/`false`；看启动日志 `Canary bug config loaded` |
| checksum 不滚 | 注解打在 Deployment metadata 而非 **pod template** | 必须在 `spec.template.metadata.annotations` |
| 改 values.yaml 的 middleware 不生效 | 忘了 `-f values-minikube.yaml` 且后者覆盖 | 统一三层 `-f` 顺序 |
| ImagePull 同 tag | 未 rm/load | 同 W1 流程 |

---

## 下一步（W6 预告）

- 安装 Argo CD；Application 指向 `infra/helm/iot-learn-lab`
- Git 改 values → Sync → 集群变化（GitOps）
- 产出 `infra/argocd/application-iot-learn-lab.yaml`

**W6 实施计划文件（待写）：** `docs/superpowers/plans/2026-07-19-stage2-w6-argocd.md`

---

## Spec 覆盖自检

| Spec 要求（Stage 2 W5 段） | 本计划 Task |
|---------------------------|-------------|
| ConfigMap 注入 DB/Redis/Kafka/Nacos | Task 2–3（延续 + 环境层 values-minikube） |
| 一条命令切换 v2 与 canary-bug-enabled | Task 6 |
| 面试 Helm vs Kustomize；ConfigMap 热更新限制 | 指南 + Task 7 + checksum Task 4–5 |
| `docs/stage2-helm-cheatsheet.md` | Task 7 |

---

## 执行方式

**Plan complete and saved to `docs/superpowers/plans/2026-07-19-stage2-w5-helm-values.md`. Two execution options:**

1. **Subagent-Driven（推荐）** — 按 Task 派发子代理，每 Task 后 review  
2. **Inline Execution** — 本会话按 Task 1→7 连续执行，Checkpoint 在 Task 4（checksum 装上）后  

**Which approach?**
