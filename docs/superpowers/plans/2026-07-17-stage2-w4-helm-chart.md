# Stage 2 W4：Helm Chart 骨架 + install / upgrade / rollback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 W1–W3 的裸 `infra/k8s/` manifest 收成 **Helm Chart**（`infra/helm/iot-learn-lab/`）；用 `values.yaml` / `values-v1.yaml` / `values-v2.yaml` 外置镜像、副本、中间件与 Ingress；能用 **`helm upgrade --install` / `rollback`** 部署三服务，并跑通 K4 基线脚本。

**Architecture:** 采用 **单 Chart、多 Deployment**（不做子 Chart，降低 W4 心智负担；W5 再加深 values 分层与「一条命令切 v2」）。Chart 渲染出与现网等价的 ConfigMap / Deployment / Service / Ingress；Release 名建议 `iot-learn`，Namespace 固定 `iot-learn`。裸 `infra/k8s/` **保留作对照教材**，日常部署切到 Helm。W4 **不做** Argo CD、Rollouts、APISIX 改 upstream（W6–W7）。

**Tech Stack:** Helm 3、现有 minikube + ingress-nginx、三服务镜像 `*:0.1.0-SNAPSHOT`、kubectl

**Spec 来源:** `docs/superpowers/specs/2026-07-13-stage2-k8s-gitops-design.md`（W4 段）

**前置知识指南:** `docs/superpowers/guides/2026-07-17-stage2-w4-helm-primer.md`

**前置条件（W3 已完成）：**

- [x] 三服务在 minikube `1/1 Running`；Feign / Kafka 路径已通（K2）
- [x] Ingress + NodePort `30765`/`30767`；外部 Prometheus `*-k8s` 可 UP（K3）
- [x] `scenario-k2` / `scenario-k3` 可 PASS
- [ ] WSL 已安装 **Helm 3**（`helm version`），本计划 Task 1 会检查/安装指引

**时间预算:** 1 周 × 10–15h

**W4 边界:**

| W4 做 | W4 不做 |
|-------|---------|
| Chart 骨架 + templates 覆盖三服务 + Ingress | 子 Chart / 依赖 chart（可选留给以后） |
| `values.yaml` + `values-v1` / `values-v2` | 完整「一条命令切 canary-bug」（W5） |
| `helm install` / `upgrade` / `rollback` | Argo CD（W6）/ Rollouts（W7） |
| `scenario-k4-helm-baseline.sh` | `stage2-helm-cheatsheet.md` 全文（W5 产出） |
| 部署入口切到 Helm | 删除 `infra/k8s/`（保留对照） |

---

## W4 拓扑（读完再动手）

```text
values.yaml  (+ values-v1.yaml / values-v2.yaml)
        │
        │  helm template / helm upgrade --install
        ▼
┌─ Release: iot-learn   namespace=iot-learn ──────────────────────────┐
│  ConfigMaps → Deployments → Services (NodePort) → Ingress           │
│  device-report / command-dispatch / device-report-consumer          │
└────────────────────────────┬────────────────────────────────────────┘
                             │ 行为与 W3 裸 manifest 等价
┌────────────────────────────▼────────────────────────────────────────┐
│  WSL Docker 中间件不变；Prometheus 仍 scrape NodePort               │
└─────────────────────────────────────────────────────────────────────┘
```

**与裸 YAML 的关系：**

| 以前（W1–W3） | W4 |
|---------------|-----|
| `kubectl apply -f infra/k8s/...` | `helm upgrade --install iot-learn ./infra/helm/iot-learn-lab -n iot-learn -f ...` |
| 改副本 / 镜像 → 手改 YAML 再 apply | 改 `values*.yaml` → `helm upgrade` |
| 回滚靠 git + 手动 apply | `helm rollback iot-learn` |

---

## 文件结构（W4 新增 / 修改）

```text
iot-learn-lab/
├── infra/
│   ├── k8s/                                 # 保留对照；README 注明「部署请用 Helm」
│   └── helm/
│       └── iot-learn-lab/
│           ├── Chart.yaml
│           ├── values.yaml                  # 默认（对齐当前 W3）
│           ├── values-v1.yaml               # version=v1 覆盖
│           ├── values-v2.yaml               # version=v2 / 预留镜像 tag
│           ├── .helmignore
│           └── templates/
│               ├── _helpers.tpl
│               ├── namespace.yaml            # 可选；若 ns 已存在用 lookup 或跳过
│               ├── device-report-configmap.yaml
│               ├── device-report-deployment.yaml
│               ├── device-report-service.yaml
│               ├── device-report-ingress.yaml
│               ├── command-dispatch-configmap.yaml
│               ├── command-dispatch-deployment.yaml
│               ├── command-dispatch-service.yaml
│               ├── device-report-consumer-configmap.yaml
│               ├── device-report-consumer-deployment.yaml
│               └── device-report-consumer-service.yaml
├── scripts/stage2/
│   └── scenario-k4-helm-baseline.sh         # 新建
├── docs/
│   └── stage2-interview-notes.md            # 追加 W4
└── infra/k8s/README.md                      # 追加「改用 Helm」说明

docs/superpowers/
├── plans/2026-07-17-stage2-w4-helm-chart.md     # 本文件
└── guides/2026-07-17-stage2-w4-helm-primer.md
```

---

## 学习场景 K4：Helm 基线（W4 Day 5–6）

| 项 | 内容 |
|----|------|
| **操作** | `helm upgrade --install` → 改 replicas upgrade → `helm rollback` → K2/K3 冒烟 |
| **预期** | Release deployed；upgrade 后副本变化；rollback 回到上一版；Ingress/Feign 仍通 |
| **面试** | Chart vs Release vs Values？`upgrade --install` 干什么？为何 ConfigMap 改了还要重启 Pod？ |

---

### Task 1: 安装并验证 Helm 3

**Files:**（无仓库文件）

- [ ] **Step 1: 检查是否已安装**

```bash
helm version
```

Expected: `version.BuildInfo{Version:"v3....`

若未安装（WSL）：

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
```

- [ ] **Step 2: 确认集群可访问**

```bash
kubectl get nodes
kubectl get pods -n iot-learn
```

Expected: node Ready；三服务（若仍在）Running

---

### Task 2: 创建 Chart 骨架与 `values.yaml`

**Files:**
- Create: `iot-learn-lab/infra/helm/iot-learn-lab/Chart.yaml`
- Create: `iot-learn-lab/infra/helm/iot-learn-lab/.helmignore`
- Create: `iot-learn-lab/infra/helm/iot-learn-lab/values.yaml`
- Create: `iot-learn-lab/infra/helm/iot-learn-lab/values-v1.yaml`
- Create: `iot-learn-lab/infra/helm/iot-learn-lab/values-v2.yaml`
- Create: `iot-learn-lab/infra/helm/iot-learn-lab/templates/_helpers.tpl`

- [ ] **Step 1: `Chart.yaml`**

```yaml
apiVersion: v2
name: iot-learn-lab
description: Stage 2 Helm chart for iot-learn-lab (hybrid middleware)
type: application
version: 0.1.0
appVersion: "0.1.0-SNAPSHOT"
```

- [ ] **Step 2: `.helmignore`**

```text
.DS_Store
*.md
.git
```

- [ ] **Step 3: `values.yaml`（默认对齐 W3 现状）**

```yaml
namespace: iot-learn

global:
  imagePullPolicy: IfNotPresent
  springProfilesActive: k8s

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

deviceReport:
  enabled: true
  name: device-report-service
  replicaCount: 1
  image: device-report-service:0.1.0-SNAPSHOT
  versionLabel: v1
  port: 8765
  nodePort: 30765
  dispatchBaseUrl: http://command-dispatch-service:8767
  resources:
    requests:
      memory: 512Mi
      cpu: 250m
    limits:
      memory: 1Gi
      cpu: "1000m"
  ingress:
    enabled: true
    className: nginx
    host: device-report.iot-learn.local
    annotations:
      nginx.ingress.kubernetes.io/proxy-body-size: "2m"

commandDispatch:
  enabled: true
  name: command-dispatch-service
  replicaCount: 1
  image: command-dispatch-service:0.1.0-SNAPSHOT
  versionLabel: v1
  port: 8767
  nodePort: 30767
  resources:
    requests:
      memory: 256Mi
      cpu: 100m
    limits:
      memory: 512Mi
      cpu: 500m

deviceReportConsumer:
  enabled: true
  name: device-report-consumer
  replicaCount: 1
  image: device-report-consumer:0.1.0-SNAPSHOT
  versionLabel: v1
  port: 8768
  # W3 未暴露 NodePort；W4 保持 ClusterIP
  serviceType: ClusterIP
  resources:
    requests:
      memory: 512Mi
      cpu: 250m
    limits:
      memory: 1Gi
      cpu: "1000m"
```

- [ ] **Step 4: `values-v1.yaml`**

```yaml
# 叠加：helm upgrade ... -f values.yaml -f values-v1.yaml
deviceReport:
  versionLabel: v1
  image: device-report-service:0.1.0-SNAPSHOT
commandDispatch:
  versionLabel: v1
deviceReportConsumer:
  versionLabel: v1
```

- [ ] **Step 5: `values-v2.yaml`（为 W5/W7 预留；W4 只验证能渲染）**

```yaml
# 叠加：-f values.yaml -f values-v2.yaml
# W4：先用同镜像 + versionLabel=v2，验证 label/滚动；真正 v2 镜像与 canary-bug 留给 W5
deviceReport:
  versionLabel: v2
  image: device-report-service:0.1.0-SNAPSHOT
  replicaCount: 1
commandDispatch:
  versionLabel: v1
deviceReportConsumer:
  versionLabel: v1
```

- [ ] **Step 6: `templates/_helpers.tpl`**

```yaml
{{- define "iot-learn-lab.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "iot-learn-lab.labels" -}}
app.kubernetes.io/name: {{ include "iot-learn-lab.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}
```

---

### Task 3: 编写 templates（从 `infra/k8s` 平移）

**Files:**（全部在 `iot-learn-lab/infra/helm/iot-learn-lab/templates/`）

> 原则：字段与现有裸 YAML **行为等价**；可变项一律 `{{ .Values... }}`。下面给出完整模板内容，按文件创建即可。

- [ ] **Step 1: `device-report-configmap.yaml`**

```yaml
{{- if .Values.deviceReport.enabled }}
apiVersion: v1
kind: ConfigMap
metadata:
  name: device-report-middleware
  namespace: {{ .Values.namespace }}
  labels:
    {{- include "iot-learn-lab.labels" . | nindent 4 }}
    app: {{ .Values.deviceReport.name }}
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
{{- end }}
```

- [ ] **Step 2: `device-report-deployment.yaml`**

```yaml
{{- if .Values.deviceReport.enabled }}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Values.deviceReport.name }}
  namespace: {{ .Values.namespace }}
  labels:
    {{- include "iot-learn-lab.labels" . | nindent 4 }}
    app: {{ .Values.deviceReport.name }}
spec:
  replicas: {{ .Values.deviceReport.replicaCount }}
  selector:
    matchLabels:
      app: {{ .Values.deviceReport.name }}
  template:
    metadata:
      labels:
        app: {{ .Values.deviceReport.name }}
        version: {{ .Values.deviceReport.versionLabel | quote }}
    spec:
      containers:
        - name: {{ .Values.deviceReport.name }}
          image: {{ .Values.deviceReport.image | quote }}
          imagePullPolicy: {{ .Values.global.imagePullPolicy }}
          ports:
            - containerPort: {{ .Values.deviceReport.port }}
              name: http
          envFrom:
            - configMapRef:
                name: device-report-middleware
          readinessProbe:
            httpGet:
              path: /actuator/health/readiness
              port: {{ .Values.deviceReport.port }}
            initialDelaySeconds: 30
            periodSeconds: 10
            failureThreshold: 6
          livenessProbe:
            httpGet:
              path: /actuator/health/liveness
              port: {{ .Values.deviceReport.port }}
            initialDelaySeconds: 60
            periodSeconds: 20
          resources:
            {{- toYaml .Values.deviceReport.resources | nindent 12 }}
{{- end }}
```

- [ ] **Step 3: `device-report-service.yaml`**

```yaml
{{- if .Values.deviceReport.enabled }}
apiVersion: v1
kind: Service
metadata:
  name: {{ .Values.deviceReport.name }}
  namespace: {{ .Values.namespace }}
  labels:
    {{- include "iot-learn-lab.labels" . | nindent 4 }}
    app: {{ .Values.deviceReport.name }}
spec:
  type: NodePort
  selector:
    app: {{ .Values.deviceReport.name }}
  ports:
    - name: http
      port: {{ .Values.deviceReport.port }}
      targetPort: {{ .Values.deviceReport.port }}
      nodePort: {{ .Values.deviceReport.nodePort }}
{{- end }}
```

- [ ] **Step 4: `device-report-ingress.yaml`**

```yaml
{{- if and .Values.deviceReport.enabled .Values.deviceReport.ingress.enabled }}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: device-report-ingress
  namespace: {{ .Values.namespace }}
  labels:
    {{- include "iot-learn-lab.labels" . | nindent 4 }}
    app: {{ .Values.deviceReport.name }}
  annotations:
    {{- toYaml .Values.deviceReport.ingress.annotations | nindent 4 }}
spec:
  ingressClassName: {{ .Values.deviceReport.ingress.className }}
  rules:
    - host: {{ .Values.deviceReport.ingress.host | quote }}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: {{ .Values.deviceReport.name }}
                port:
                  number: {{ .Values.deviceReport.port }}
{{- end }}
```

- [ ] **Step 5: `command-dispatch-configmap.yaml`**

```yaml
{{- if .Values.commandDispatch.enabled }}
apiVersion: v1
kind: ConfigMap
metadata:
  name: command-dispatch-middleware
  namespace: {{ .Values.namespace }}
  labels:
    {{- include "iot-learn-lab.labels" . | nindent 4 }}
    app: {{ .Values.commandDispatch.name }}
data:
  SPRING_PROFILES_ACTIVE: {{ .Values.global.springProfilesActive | quote }}
{{- end }}
```

- [ ] **Step 6: `command-dispatch-deployment.yaml`**

```yaml
{{- if .Values.commandDispatch.enabled }}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Values.commandDispatch.name }}
  namespace: {{ .Values.namespace }}
  labels:
    {{- include "iot-learn-lab.labels" . | nindent 4 }}
    app: {{ .Values.commandDispatch.name }}
spec:
  replicas: {{ .Values.commandDispatch.replicaCount }}
  selector:
    matchLabels:
      app: {{ .Values.commandDispatch.name }}
  template:
    metadata:
      labels:
        app: {{ .Values.commandDispatch.name }}
        version: {{ .Values.commandDispatch.versionLabel | quote }}
    spec:
      containers:
        - name: {{ .Values.commandDispatch.name }}
          image: {{ .Values.commandDispatch.image | quote }}
          imagePullPolicy: {{ .Values.global.imagePullPolicy }}
          ports:
            - containerPort: {{ .Values.commandDispatch.port }}
              name: http
          envFrom:
            - configMapRef:
                name: command-dispatch-middleware
          readinessProbe:
            httpGet:
              path: /actuator/health/readiness
              port: {{ .Values.commandDispatch.port }}
            initialDelaySeconds: 20
            periodSeconds: 10
            failureThreshold: 6
          livenessProbe:
            httpGet:
              path: /actuator/health/liveness
              port: {{ .Values.commandDispatch.port }}
            initialDelaySeconds: 40
            periodSeconds: 20
          resources:
            {{- toYaml .Values.commandDispatch.resources | nindent 12 }}
{{- end }}
```

- [ ] **Step 7: `command-dispatch-service.yaml`**

```yaml
{{- if .Values.commandDispatch.enabled }}
apiVersion: v1
kind: Service
metadata:
  name: {{ .Values.commandDispatch.name }}
  namespace: {{ .Values.namespace }}
  labels:
    {{- include "iot-learn-lab.labels" . | nindent 4 }}
    app: {{ .Values.commandDispatch.name }}
spec:
  type: NodePort
  selector:
    app: {{ .Values.commandDispatch.name }}
  ports:
    - name: http
      port: {{ .Values.commandDispatch.port }}
      targetPort: {{ .Values.commandDispatch.port }}
      nodePort: {{ .Values.commandDispatch.nodePort }}
{{- end }}
```

- [ ] **Step 8: consumer 三件套**

`device-report-consumer-configmap.yaml`：

```yaml
{{- if .Values.deviceReportConsumer.enabled }}
apiVersion: v1
kind: ConfigMap
metadata:
  name: device-report-consumer-middleware
  namespace: {{ .Values.namespace }}
  labels:
    {{- include "iot-learn-lab.labels" . | nindent 4 }}
    app: {{ .Values.deviceReportConsumer.name }}
data:
  DB_HOST: {{ .Values.middleware.dbHost | quote }}
  DB_PORT: {{ .Values.middleware.dbPort | quote }}
  DB_USERNAME: {{ .Values.middleware.dbUsername | quote }}
  DB_PASSWORD: {{ .Values.middleware.dbPassword | quote }}
  NACOS_ADDR: {{ .Values.middleware.nacosAddr | quote }}
  SPRING_PROFILES_ACTIVE: {{ .Values.global.springProfilesActive | quote }}
  KAFKA_BOOTSTRAP: {{ .Values.middleware.kafkaBootstrap | quote }}
  KAFKA_TOPIC: {{ .Values.middleware.kafkaTopic | quote }}
  KAFKA_CONSUMER_GROUP_ID: {{ .Values.middleware.kafkaConsumerGroupId | quote }}
{{- end }}
```

`device-report-consumer-deployment.yaml`：

```yaml
{{- if .Values.deviceReportConsumer.enabled }}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Values.deviceReportConsumer.name }}
  namespace: {{ .Values.namespace }}
  labels:
    {{- include "iot-learn-lab.labels" . | nindent 4 }}
    app: {{ .Values.deviceReportConsumer.name }}
spec:
  replicas: {{ .Values.deviceReportConsumer.replicaCount }}
  selector:
    matchLabels:
      app: {{ .Values.deviceReportConsumer.name }}
  template:
    metadata:
      labels:
        app: {{ .Values.deviceReportConsumer.name }}
        version: {{ .Values.deviceReportConsumer.versionLabel | quote }}
    spec:
      containers:
        - name: {{ .Values.deviceReportConsumer.name }}
          image: {{ .Values.deviceReportConsumer.image | quote }}
          imagePullPolicy: {{ .Values.global.imagePullPolicy }}
          ports:
            - containerPort: {{ .Values.deviceReportConsumer.port }}
              name: http
          envFrom:
            - configMapRef:
                name: device-report-consumer-middleware
          readinessProbe:
            httpGet:
              path: /actuator/health/readiness
              port: {{ .Values.deviceReportConsumer.port }}
            initialDelaySeconds: 30
            periodSeconds: 10
            failureThreshold: 6
          livenessProbe:
            httpGet:
              path: /actuator/health/liveness
              port: {{ .Values.deviceReportConsumer.port }}
            initialDelaySeconds: 60
            periodSeconds: 20
          resources:
            {{- toYaml .Values.deviceReportConsumer.resources | nindent 12 }}
{{- end }}
```

`device-report-consumer-service.yaml`：

```yaml
{{- if .Values.deviceReportConsumer.enabled }}
apiVersion: v1
kind: Service
metadata:
  name: {{ .Values.deviceReportConsumer.name }}
  namespace: {{ .Values.namespace }}
  labels:
    {{- include "iot-learn-lab.labels" . | nindent 4 }}
    app: {{ .Values.deviceReportConsumer.name }}
spec:
  type: {{ .Values.deviceReportConsumer.serviceType }}
  selector:
    app: {{ .Values.deviceReportConsumer.name }}
  ports:
    - name: http
      port: {{ .Values.deviceReportConsumer.port }}
      targetPort: {{ .Values.deviceReportConsumer.port }}
{{- end }}
```

- [ ] **Step 9: 本地渲染自检（不写集群）**

```bash
cd iot-learn-lab
helm lint infra/helm/iot-learn-lab
helm template iot-learn infra/helm/iot-learn-lab \
  -f infra/helm/iot-learn-lab/values.yaml \
  -f infra/helm/iot-learn-lab/values-v1.yaml \
  -n iot-learn | head -80
```

Expected: `lint` 无 Error；输出含 Deployment / Service / Ingress 等

---

### Task 4: 从裸 manifest 迁移到 Helm Release

**Files:**（无新文件；操作集群）

> 已有对象由 `kubectl apply` 创建，**没有** Helm 归属标签。学习环境推荐：**删应用资源 → Helm 重建**（Namespace `iot-learn` 可保留）。

- [ ] **Step 1: 删除旧应用对象（保留 namespace）**

```bash
kubectl delete ingress device-report-ingress -n iot-learn --ignore-not-found
kubectl delete deploy,svc,cm -n iot-learn \
  -l 'app in (device-report-service,command-dispatch-service,device-report-consumer)' \
  --ignore-not-found

# 若 label 选择器未删干净，按名删：
kubectl delete deploy device-report-service command-dispatch-service device-report-consumer -n iot-learn --ignore-not-found
kubectl delete svc device-report-service command-dispatch-service device-report-consumer -n iot-learn --ignore-not-found
kubectl delete cm device-report-middleware command-dispatch-middleware device-report-consumer-middleware -n iot-learn --ignore-not-found
```

- [ ] **Step 2: 确认镜像仍在 minikube**

```bash
minikube image ls | grep -E 'device-report|command-dispatch' || true
# 若缺失则重新 load 三张镜像（同 W2）
```

- [ ] **Step 3: 首次安装**

```bash
kubectl get ns iot-learn >/dev/null 2>&1 || kubectl apply -f infra/k8s/namespace.yaml

helm upgrade --install iot-learn infra/helm/iot-learn-lab \
  -n iot-learn \
  -f infra/helm/iot-learn-lab/values.yaml \
  -f infra/helm/iot-learn-lab/values-v1.yaml \
  --wait --timeout 5m

helm status iot-learn -n iot-learn
kubectl get pods,svc,ingress -n iot-learn
```

Expected: `STATUS: deployed`；三 Pod `1/1`；NodePort / Ingress 与 W3 一致

- [ ] **Step 4: 冒烟（复用 K2/K3）**

```bash
./scripts/stage2/scenario-k2-three-services.sh
./scripts/stage2/scenario-k3-ingress-baseline.sh
```

Expected: `K2 PASS` / `K3 PASS`（Prom 若 DOWN，再执行一次 `docker network connect minikube prometheus-learn`）

---

### Task 5: 练习 upgrade 与 rollback

**Files:**（临时改 values，或用 `--set`）

- [ ] **Step 1: upgrade——把 report 副本改为 2**

```bash
helm upgrade iot-learn infra/helm/iot-learn-lab \
  -n iot-learn \
  -f infra/helm/iot-learn-lab/values.yaml \
  -f infra/helm/iot-learn-lab/values-v1.yaml \
  --set deviceReport.replicaCount=2 \
  --wait --timeout 5m

kubectl get deploy device-report-service -n iot-learn
helm history iot-learn -n iot-learn
```

Expected: `READY` 副本 2；history 至少 2 条 revision

- [ ] **Step 2: rollback 回上一版**

```bash
helm rollback iot-learn 1 -n iot-learn --wait
# 若 revision 编号不同，用 helm history 看到的「安装时那一版」

kubectl get deploy device-report-service -n iot-learn
# 期望 replicas 回到 1
```

- [ ] **Step 3: 用 values-v2 做一次「只改 label」的 upgrade（不引入新镜像）**

```bash
helm upgrade iot-learn infra/helm/iot-learn-lab \
  -n iot-learn \
  -f infra/helm/iot-learn-lab/values.yaml \
  -f infra/helm/iot-learn-lab/values-v2.yaml \
  --wait --timeout 5m

kubectl get pods -n iot-learn -l app=device-report-service --show-labels | grep version
```

Expected: Pod 带 `version=v2`；再 `-f values-v1.yaml` upgrade 回去亦可

---

### Task 6: 场景脚本 K4 + 文档

**Files:**
- Create: `iot-learn-lab/scripts/stage2/scenario-k4-helm-baseline.sh`
- Modify: `iot-learn-lab/infra/k8s/README.md`
- Modify: `iot-learn-lab/docs/stage2-interview-notes.md`
- Modify: `iot-learn-lab/README.md`（Stage 2 部署改为 Helm 优先）

- [ ] **Step 1: 创建 `scenario-k4-helm-baseline.sh`**

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

echo "== K4: Helm baseline (install state + history) =="

helm status "$REL" -n "$NS"
helm history "$REL" -n "$NS" | head -20

kubectl get deploy,svc,ingress -n "$NS"

echo "-- template dry-run (lint values-v1) --"
helm template "$REL" "$CHART" \
  -n "$NS" \
  -f "${CHART}/values.yaml" \
  -f "${CHART}/values-v1.yaml" >/dev/null

echo "-- Ingress health --"
curl -sf -H "Host: ${INGRESS_HOST}" "http://${MINIKUBE_IP}/actuator/health" | head -c 200
echo

echo "-- NodePort metrics head --"
curl -sf "http://${MINIKUBE_IP}:${REPORT_NODE_PORT}/actuator/prometheus" | head -c 80
echo

echo
echo "K4 PASS: Helm release healthy; Ingress + NodePort reachable"
```

```bash
chmod +x iot-learn-lab/scripts/stage2/scenario-k4-helm-baseline.sh
iot-learn-lab/scripts/stage2/scenario-k4-helm-baseline.sh
```

Expected: `K4 PASS`

- [ ] **Step 2: `infra/k8s/README.md` 顶部追加**

```markdown
> **W4+ 部署入口：** 请使用 `infra/helm/iot-learn-lab/`（\`helm upgrade --install\`）。  
> 本目录裸 YAML **保留作对照与排障**，勿与 Helm Release 混用同一批对象（易归属冲突）。
```

并追加「W4：Helm」短节（install 命令 + `scenario-k4-helm-baseline.sh`）。

- [ ] **Step 3: 面试笔记追加 W4 场景表 + 自测题骨架**（可先填空，执行后补全）

题目至少包括：Chart / Release / Values；`upgrade --install`；Helm 改 ConfigMap 为何仍要重启 Pod；Helm vs 裸 apply；`values-v1` 与 `values-v2` 叠加顺序。

---

## W4 完成标准（Checklist）

- [ ] `helm version` 为 v3；`helm lint` Chart 通过
- [ ] `infra/helm/iot-learn-lab/` 含 Chart.yaml、values*.yaml、三服务 templates + Ingress
- [ ] `helm upgrade --install iot-learn ...` 成功；三 Pod Ready
- [ ] 完成一次 `--set replicaCount=2` 的 upgrade + `helm rollback`
- [ ] `values-v2.yaml` 可把 `version` label 打成 v2
- [ ] `scenario-k4-helm-baseline.sh` 输出 `K4 PASS`；K2/K3 仍可 PASS
- [ ] `infra/k8s/README.md` / 主 README 标明部署改用 Helm
- [ ] `stage2-interview-notes.md` 有 W4 章节

---

## W4 面试话术速记

| 问题 | 答法 |
|------|------|
| Chart？ | 模板 + 默认 values 的安装包 |
| Release？ | Chart 在集群里的一次安装实例（有 revision 历史） |
| Values？ | 渲染时注入的配置；多 `-f` 后者覆盖前者 |
| 为何用 Helm？ | 同一套清单多环境/多版本；upgrade/rollback 可审计 |
| 改 ConfigMap？ | Helm 会更新对象，但 **envFrom 仍要滚动 Pod**（与 W2 相同） |
| 与 Kustomize？ | Helm 偏包管理+生命周期；Kustomize 偏无模板叠加；本阶段学 Helm |

---

## 常见踩坑

| 现象 | 原因 | 处理 |
|------|------|------|
| `cannot re-use a name that is still in use` / 归属冲突 | 裸 YAML 对象与 Helm 抢同一 name | Task 4 先删再 install |
| `ImagePullBackOff` | 迁移时镜像被清 | `minikube image load` |
| upgrade 改了 ConfigMap 业务仍旧 | 未滚动 | `kubectl rollout restart` 或在 Deployment 加 checksum 注解（W5 可加） |
| `values-v2` 不生效 | `-f` 顺序反了 | 先 `values.yaml` 再 `values-v2.yaml` |
| NodePort 冲突 | 集群里残留旧 Service | `kubectl get svc -A \| grep 30765` |
| lint 报错 | YAML 缩进 / `{{- if }}` 未闭合 | `helm template` 看完整报错 |

---

## 下一步（W5）

- 加深 values：多环境（如 `values-minikube.yaml`）与中间件地址一处改全域
- 一条命令切换 v2 + `canary-bug-enabled`（对接 Phase 4）
- Deployment 增加 ConfigMap checksum 注解，upgrade ConfigMap 时自动滚 Pod
- 产出 `iot-learn-lab/docs/stage2-helm-cheatsheet.md`
- 面试：Helm vs Kustomize

**W5 实施计划：** `docs/superpowers/plans/2026-07-19-stage2-w5-helm-values.md`  
**W5 前置指南：** `docs/superpowers/guides/2026-07-19-stage2-w5-helm-values.md`

---

## Spec 覆盖自检

| Spec 要求（Stage 2 W4 段） | 本计划 Task |
|---------------------------|-------------|
| Chart / Release / Values / Templates 理论 | 指南 + Task 2–3 |
| `infra/helm/iot-learn-lab/`；单 chart 多 deployment | Task 2–3 |
| `helm install` / `upgrade` / `rollback` | Task 4–5 |
| `values.yaml`、`values-v1.yaml`、`values-v2.yaml` | Task 2、5 |

---

## 执行方式

**Plan complete and saved to `docs/superpowers/plans/2026-07-17-stage2-w4-helm-chart.md`. Two execution options:**

1. **Subagent-Driven（推荐）** — 按 Task 派发子代理，每 Task 后 review  
2. **Inline Execution** — 本会话按 Task 1→6 连续执行，Checkpoint 在 Task 4（首次 helm install）后  

**Which approach?**
