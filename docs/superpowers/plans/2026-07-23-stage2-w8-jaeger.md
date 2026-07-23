# Stage 2 W8：Jaeger + OpenTelemetry 分布式追踪 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在三服务接入 **Micrometer Tracing + OTLP**，部署 **Jaeger all-in-one**，在 UI 中看到 `POST /reports` / Feign / Kafka consumer 相关 trace；产出 runbook 与 `scenario-k8-jaeger-trace.sh`。

**Architecture:** 延续混合架构——**Jaeger 放在 WSL Docker**（与 Prometheus 同类可观测组件），业务 Pod 经 `host.minikube.internal` 上报 OTLP（HTTP `4318` 或 gRPC `4317`）。应用侧用 Spring Boot 3 官方路线：`micrometer-tracing-bridge-otel` + OTLP exporter；采样学习环境设为 `1.0`。**不做** Tempo/Zipkin 双后端、不做 Ingress 接入 span、不做 CI 改 image tag（W9–W10）。

**Tech Stack:** Spring Boot 3.3、Micrometer Tracing、OpenTelemetry OTLP、Jaeger all-in-one、现有 Helm/Argo、minikube

**Spec 来源:** `docs/superpowers/specs/2026-07-13-stage2-k8s-gitops-design.md`（W8 / Block D）

**前置知识指南:** `docs/superpowers/guides/2026-07-23-stage2-w8-jaeger.md`

**前置条件（W7 已完成）：**

- [x] 三服务在 `iot-learn` 可访问；Ingress / NodePort 可用
- [x] Feign：`reports-with-dispatch`；Kafka：`reports-async` + consumer
- [x] Argo CD 可 Sync Chart；改 ConfigMap 能滚动/金丝雀更新 Pod
- [ ] 能 `docker` 起新容器（或等价 compose）；Pod 能访问 `host.minikube.internal`

**时间预算:** 1 周 × 10–15h

**W8 边界:**

| W8 做 | W8 不做 |
|-------|---------|
| Jaeger all-in-one（Docker 优先） | Zipkin 独立部署；Grafana Tempo |
| 三服务 OTLP → Jaeger | Service Mesh 自动注入 |
| HTTP + Feign +（尽量）Kafka span | 全量 DB/Redis 细粒度手工埋点 |
| `stage2-tracing-runbook.md` + `scenario-k8` | CI/CD（W9–W10）；修 W7 Prom 按 Pod scrape（可备注对照） |

---

## W8 拓扑（读完再动手）

```text
Ingress / curl
    → device-report-service (HTTP span)
        ├─ Feign → command-dispatch-service (client + server span)
        └─ Kafka produce → device-report-consumer (consumer span，尽力)
    → 各服务 OTLP exporter
         → host.minikube.internal:4318 (OTLP/HTTP)
              → Jaeger all-in-one (WSL Docker)
                   → UI :16686
```

**与可观测三支柱对照：**

| 支柱 | 本 lab 已有 / W8 |
|------|------------------|
| Metrics | Prometheus（W3+） |
| Logs | 容器日志 / `kubectl logs` |
| Traces | **W8 Jaeger** |

---

## 文件结构（W8 新增 / 修改）

```text
iot-learn-lab/
├── pom.xml                                      # 可选：统一 tracing 依赖版本
├── device-report-service/
│   ├── pom.xml                                  # tracing + otlp
│   └── src/main/resources/application-k8s.yml   # exporter endpoint / sampling
├── command-dispatch-service/                    # 同上
├── device-report-consumer/                      # 同上 + kafka observation
├── infra/
│   ├── jaeger/
│   │   ├── docker-compose-jaeger.yml
│   │   └── README.md
│   └── helm/iot-learn-lab/
│       ├── values.yaml                          # middleware.otlpEndpoint 等
│       └── templates/*-configmap.yaml           # OTEL_/MANAGEMENT_ 环境变量
├── scripts/stage2/
│   └── scenario-k8-jaeger-trace.sh
└── docs/
    ├── stage2-tracing-runbook.md                # 主产出
    └── stage2-interview-notes.md                # 追加 W8

docs/superpowers/
├── plans/2026-07-23-stage2-w8-jaeger.md         # 本文件
├── guides/2026-07-23-stage2-w8-jaeger.md
└── specs/2026-07-13-stage2-k8s-gitops-design.md
```

---

## 学习场景 K8：全链路 Trace（W8 Day 5–6）

| 项 | 内容 |
|----|------|
| **操作** | Jaeger Ready → 打 `reports` / `reports-with-dispatch` /（可选）`reports-async` → UI 按 service 搜到 span 树 |
| **预期** | `scenario-k8-jaeger-trace.sh` → `K8 PASS`；至少一条跨 report↔dispatch 的 trace |
| **面试** | Trace vs Span？三支柱？采样率？为何 Kafka 跨进程难于 HTTP？OTLP 与 Zipkin 格式？ |

---

### Task 1: 部署 Jaeger all-in-one（Docker）

**Files:**

- Create: `iot-learn-lab/infra/jaeger/docker-compose-jaeger.yml`
- Create: `iot-learn-lab/infra/jaeger/README.md`

- [ ] **Step 1: compose 文件**

完整文件见仓库：`iot-learn-lab/infra/jaeger/docker-compose-jaeger.yml`（也可自行复制到 WSL 同名目录）。

要点（相对早期示意版的扩充）：

| 项 | 选择 |
|----|------|
| 镜像 | `jaegertracing/all-in-one:1.76.0`（1.x 末代稳定线；仍环境变量配置，比 2.x 轻、省事） |
| 存储 | Badger → 挂载 `./data`（与 compose 同级）；`BADGER_SPAN_STORE_TTL=72h` |
| 健康检查 | admin `http://127.0.0.1:14269/`（端口映射 `14269`） |
| 网络 | 专用 bridge `iot-learn-jaeger`（不并入 Prometheus/Kafka 网；Pod 经宿主机端口访问） |
| 资源 | limits：CPU 0.5 / 内存 512M |

```yaml
# 摘录；以 infra/jaeger/docker-compose-jaeger.yml 为准
name: iot-learn-jaeger

services:
  jaeger:
    image: jaegertracing/all-in-one:1.76.0
    container_name: jaeger-learn
    hostname: jaeger
    restart: unless-stopped
    environment:
      TZ: Asia/Shanghai
      COLLECTOR_OTLP_ENABLED: "true"
      SPAN_STORAGE_TYPE: badger
      BADGER_EPHEMERAL: "false"
      BADGER_DIRECTORY_VALUE: /badger/data
      BADGER_DIRECTORY_KEY: /badger/key
      BADGER_SPAN_STORE_TTL: 72h
    ports:
      - "16686:16686"   # UI
      - "4317:4317"     # OTLP gRPC
      - "4318:4318"     # OTLP HTTP
      - "14269:14269"   # admin / health
    volumes:
      - ./data:/badger
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1:14269/ || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 5
      start_period: 20s
    deploy:
      resources:
        limits:
          cpus: "0.50"
          memory: 512M
        reservations:
          cpus: "0.10"
          memory: 128M
    networks:
      - jaeger-network

networks:
  jaeger-network:
    name: iot-learn-jaeger
    driver: bridge
```

- [ ] **Step 2: 启动并自检**（在 WSL 自行建目录 / 放 compose 后执行）

```bash
cd iot-learn-lab/infra/jaeger   # 或你放置 compose 的目录
mkdir -p data
docker compose -f docker-compose-jaeger.yml up -d
docker compose -f docker-compose-jaeger.yml ps   # 期望 healthy
curl -sf http://127.0.0.1:16686/ | head -c 200
curl -sf http://127.0.0.1:14269/                 # admin 健康
# 浏览器：http://192.168.19.64:16686 （WSL IP 按实际）
```

- [ ] **Step 3: 从「未来 Pod 视角」测 OTLP 端口可达性**

```bash
# 在 minikube 节点或临时 Pod 测 host.minikube.internal
kubectl -n iot-learn run curl-otlp --rm -it --image=curlimages/curl --restart=Never -- \
  curl -sS -m 3 -o /dev/null -w "%{http_code}\n" \
  http://host.minikube.internal:4318/
# 4318 可能返回 404/405 仍说明端口通；连接超时才是网络问题
```

- [ ] **Step 4: README 写清端口、UI、与 Prometheus 对照、排障**

- [ ] **Step 5: Commit**

```bash
git add iot-learn-lab/infra/jaeger/
git commit -m "$(cat <<'EOF'
feat(stage2-w8): add Jaeger all-in-one docker compose

EOF
)"
```

---

### Task 2: 父 POM / 三服务引入 Tracing 依赖

**Files:**

- Modify: `iot-learn-lab/device-report-service/pom.xml`
- Modify: `iot-learn-lab/command-dispatch-service/pom.xml`
- Modify: `iot-learn-lab/device-report-consumer/pom.xml`
- Modify（可选）: `iot-learn-lab/pom.xml` dependencyManagement

- [ ] **Step 1: 每模块增加（版本跟随 Boot BOM）**

```xml
<dependency>
  <groupId>io.micrometer</groupId>
  <artifactId>micrometer-tracing-bridge-otel</artifactId>
</dependency>
<dependency>
  <groupId>io.opentelemetry</groupId>
  <artifactId>opentelemetry-exporter-otlp</artifactId>
</dependency>
```

- [ ] **Step 2: `mvn -pl ...,... -am -DskipTests package` 确认可编译**

- [ ] **Step 3: Commit**

```bash
git commit -m "$(cat <<'EOF'
feat(stage2-w8): add micrometer-tracing and OTLP exporter deps

EOF
)"
```

---

### Task 3: application-k8s 与 Helm 注入 OTLP 配置

**Files:**

- Modify: 各服务 `application-k8s.yml`（或共用片段）
- Modify: `values.yaml` / `values-minikube.yaml` — `middleware.otlpEndpoint`
- Modify: 三个 ConfigMap 模板 — 导出环境变量

- [ ] **Step 1: 应用配置要点（示意）**

```yaml
management:
  tracing:
    sampling:
      probability: 1.0   # 学习环境全采样；生产常 0.01~0.1
  otlp:
    tracing:
      endpoint: ${OTEL_EXPORTER_OTLP_ENDPOINT:http://host.minikube.internal:4318/v1/traces}
# 视 Boot/依赖版本，也可能用：
# management.opentelemetry.tracing.export.otlp.endpoint=...
```

以 **启动日志 / 官方 3.3 文档** 为准校正属性名；目标是 traces 发到 Jaeger OTLP HTTP。

Kafka（consumer / producer）尽量打开 observation（Boot 3.2+ 常见）：

```yaml
spring:
  kafka:
    listener:
      observation-enabled: true
    template:
      observation-enabled: true
```

- [ ] **Step 2: Helm ConfigMap 增加**

```yaml
OTEL_EXPORTER_OTLP_ENDPOINT: {{ .Values.middleware.otlpEndpoint | quote }}
# 或 MANAGEMENT_OTLP_TRACING_ENDPOINT / 与 yml 占位符一致的键
```

`values-minikube.yaml` 示例：

```yaml
middleware:
  otlpEndpoint: "http://host.minikube.internal:4318/v1/traces"
```

- [ ] **Step 3: 本地/IDEA 也可先指 `http://127.0.0.1:4318/v1/traces` 验证，再进集群**

- [ ] **Step 4: Commit**

---

### Task 4: 重建镜像并 GitOps 发布

**Files:** Dockerfile 无强制改；需 **重新 build + `minikube image load`**（Task 2 的 tracing 依赖必须进镜像里的 jar）

- [ ] **Step 1: 构建三镜像并 load 进 minikube**（沿用 W1 习惯，下文展开）

#### 1.0 为什么本步不能省

| 改动类型 | 只改 ConfigMap / values？ | 要 rebuild + load？ |
|----------|---------------------------|---------------------|
| `OTEL_EXPORTER_OTLP_ENDPOINT` 环境变量 | 够（Sync + 重启 Pod） | 否 |
| `application-k8s.yml` 打进镜像 | — | **要** |
| `pom.xml` 增加 tracing / OTLP 依赖 | — | **要**（jar 内容变了） |

W8 已改 pom +（通常）`application-k8s.yml` → **三服务都必须重建镜像**。tag 仍用 `0.1.0-SNAPSHOT`（与 Helm `values.yaml` 一致），因此还要处理「同 tag 覆盖」问题。

#### 1.1 前置条件

在 **WSL** 执行（与 W1 相同；Windows 本机 Docker 与 minikube 节点不是同一套镜像库）。

```bash
# 1) 集群与上下文
minikube status
kubectl config current-context   # 期望 minikube

# 2) Jaeger 已在 WSL 起来（Task 1），且 Pod 能打到 4318
docker ps --filter name=jaeger-learn --format '{{.Names}} {{.Status}}'

# 3) 工作目录必须是多模块根（Dockerfile 的 COPY 相对路径依赖这里）
cd /path/to/Operations-And-Maintenance/iot-learn-lab
# 可用脚本里的默认 tag（可选）
# source scripts/stage2/env.sh
# echo "$IMAGE_DEVICE_REPORT" "$IMAGE_COMMAND_DISPATCH" "$IMAGE_DEVICE_REPORT_CONSUMER"
```

镜像名（与 Chart 一致，不要改 tag，除非你同步改 values）：

| 服务 | 镜像 tag |
|------|----------|
| device-report-service | `device-report-service:0.1.0-SNAPSHOT` |
| command-dispatch-service | `command-dispatch-service:0.1.0-SNAPSHOT` |
| device-report-consumer | `device-report-consumer:0.1.0-SNAPSHOT` |

#### 1.2 构建三镜像（宿主机 Docker）

多阶段 Dockerfile 会在 build 内跑 `mvn package`，**上下文 `.` = `iot-learn-lab/`**（与 W1 Task 4/5 相同）：

```bash
cd iot-learn-lab

docker build -f device-report-service/Dockerfile \
  -t device-report-service:0.1.0-SNAPSHOT .

docker build -f command-dispatch-service/Dockerfile \
  -t command-dispatch-service:0.1.0-SNAPSHOT .

docker build -f device-report-consumer/Dockerfile \
  -t device-report-consumer:0.1.0-SNAPSHOT .
```

Expected：每条命令末尾出现 `exporting to image` / `naming to ...` 且 exit code 0。

自检（宿主机侧）：

```bash
docker images | grep -E 'device-report-service|command-dispatch-service|device-report-consumer'
```

> 可选加速：若本机已 `mvn package` 且 Dockerfile 支持只 COPY jar，可走本地 jar 流程；**本 lab 标准路径仍是上面的 docker build**（与 W1 / `iot-learn-lab/README.md` 一致）。

#### 1.3 同 tag 载入 minikube（推荐：先停 Argo CD auto-sync）

`imagePullPolicy: IfNotPresent` + 相同 tag 时，节点上旧层可能一直被沿用。W1 / 面试笔记约定：停 Pod → `image rm` → `image load` → 再拉起。

**W6+ 注意：** 若 Application `iot-learn-lab` 开了 **AUTO-SYNC / selfHeal**，你 `kubectl scale … --replicas=0` 后，Argo CD 会按 Git（Helm values）把副本写回去（例如 `values-v1.yaml` 里 report `replicaCount: 5`）。  
**推荐做法 A：先暂停自动同步，再换镜像**（本 lab 实操路径）。

当前资源分工（W7 后）：

| 服务 | 控制器 | scale 目标 |
|------|--------|------------|
| device-report-service | **Rollout** | `rollout/device-report-service`（**没有**同名 Deployment） |
| command-dispatch-service | Deployment | `deploy/command-dispatch-service` |
| device-report-consumer | Deployment | `deploy/device-report-consumer` |

```bash
NS=iot-learn
APP=iot-learn-lab          # Argo CD Application 名（见 infra/argocd/application-iot-learn-lab.yaml）
NS_ARGO=argocd

# ========== 0) 暂停 Argo CD 自动同步（做法 A）==========
# 方式 0a：argocd CLI（有 CLI 时）
argocd app set "$APP" --sync-policy none

# 方式 0b：无 CLI 时用 kubectl 去掉 automated（与 0a 二选一）
# kubectl -n "$NS_ARGO" patch application "$APP" --type json \
#   -p='[{"op":"remove","path":"/spec/syncPolicy/automated"}]'

# 方式 0c：Argo CD UI → Application iot-learn-lab → DETAILS → 关闭 AUTO-SYNC / SELF HEAL

# 确认已不再 Automated（SPEC 里不应再看到 automated: {...}）
kubectl -n "$NS_ARGO" get application "$APP" -o jsonpath='{.spec.syncPolicy}' ; echo

# ========== 1) 缩副本到 0（镜像不被占用，才能 image rm）==========
kubectl -n "$NS" scale rollout/device-report-service --replicas=0
kubectl -n "$NS" scale deploy/command-dispatch-service --replicas=0
kubectl -n "$NS" scale deploy/device-report-consumer --replicas=0

# 确认业务 Pod 已消失（不应再被 Argo 立刻拉起）
kubectl -n "$NS" get pods
# 期望：无 device-report-service / command-dispatch / consumer 的 Running Pod

# ========== 2) 从 minikube 节点删旧镜像 ==========
minikube image rm device-report-service:0.1.0-SNAPSHOT || true
minikube image rm command-dispatch-service:0.1.0-SNAPSHOT || true
minikube image rm device-report-consumer:0.1.0-SNAPSHOT || true

# ========== 3) 灌入刚 docker build 的镜像 ==========
minikube image load device-report-service:0.1.0-SNAPSHOT
minikube image load command-dispatch-service:0.1.0-SNAPSHOT
minikube image load device-report-consumer:0.1.0-SNAPSHOT

# ========== 4) 确认节点上有图 ==========
minikube image ls | grep -E 'device-report-service|command-dispatch-service|device-report-consumer'
# 或：minikube ssh -- docker images | grep -E 'device-report|command-dispatch'

# ========== 5) 恢复 Argo 自动同步，并 Sync（按 Git 拉回期望副本）==========
# CLI：
argocd app set "$APP" --sync-policy automated --auto-prune --self-heal
argocd app sync "$APP"

# 无 CLI 时恢复 automated + 触发 sync：
# kubectl -n "$NS_ARGO" patch application "$APP" --type merge -p '{
#   "spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true},"syncOptions":["CreateNamespace=true"]}}
# }'
# kubectl -n "$NS_ARGO" patch application "$APP" --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"HEAD"}}}'
# 或在 UI 打开 AUTO-SYNC 后点 SYNC

# ========== 6) 等 Ready ==========
kubectl -n "$NS" get pods -w
# report 为 Rollout 时也可：
# kubectl -n "$NS" argo rollouts status device-report-service --watch
kubectl -n "$NS" rollout status deploy/command-dispatch-service --timeout=180s
kubectl -n "$NS" rollout status deploy/device-report-consumer --timeout=180s
```

Expected：

- Sync 后 report 副本数与当前 valueFiles 一致（常用 `values-v1.yaml` → **5**，不是 1）  
- 三服务 Pod `Running` / `Ready`  
- `ImagePullBackOff` → 回到步骤 2–3（镜像未进节点或 tag 写错）

**若未暂停 auto-sync 就 scale 0：** Pod 会在几十秒内被拉回（AGE 很新）——属正常 GitOps 纠偏，不是 Helm 守护进程。此时 `image rm` 常因占用失败，应回到做法 A。

**无 Argo、仅 Helm 时：** 可跳过步骤 0/5，scale 0 → rm → load 后自行 `scale` 回副本或 `helm upgrade ... --wait`（见 `stage2-helm-cheatsheet.md`）。

#### 1.4 Step 1 完成标准（再进 Step 2 GitOps）

- [ ] 已按做法 A：auto-sync 暂停 → scale 0 → `image rm/load` → 恢复 sync  
- [ ] 宿主机 `docker images` 有三服务 `0.1.0-SNAPSHOT`（构建时间是本次）  
- [ ] `minikube image ls`（或 ssh 内 `docker images`）同样有三服务  
- [ ] 业务 Pod 已重新拉起且 Ready（report 可能为 5 副本）  
- [ ] （可选预检）任选一 Pod：`kubectl exec ... -- printenv | grep OTEL` —— 若 ConfigMap 已含 endpoint，此处应能看到；**若还没有，留给 Step 2 Sync ConfigMap 后再查**

> **只完成 Step 1 不够出链路：** 新 jar 在跑，但若 ConfigMap 尚未注入 `OTEL_EXPORTER_OTLP_ENDPOINT`，仍可能推不到 Jaeger。Step 2 负责 values/ConfigMap → Argo Sync（或 `helm upgrade`）。

对照文档：

- W1 计划 Task 4–5：`docs/superpowers/plans/2026-07-13-stage2-w1-minikube-dockerfile.md`  
- 同 tag 换镜像速查：`iot-learn-lab/docs/stage2-helm-cheatsheet.md`  
- Argo Application：`iot-learn-lab/infra/argocd/application-iot-learn-lab.yaml`（名 `iot-learn-lab`）  
- 命令汇总：`iot-learn-lab/README.md`、`iot-learn-lab/infra/k8s/README.md`

- [ ] **Step 2: 改 ConfigMap checksum 或 bump 无害字段 → push → Argo Sync**

确保新 Pod 带 OTLP 环境变量：

```bash
kubectl -n iot-learn get pods -l app=device-report-service -o name | head -1 | \
  xargs -I{} kubectl -n iot-learn exec {} -- printenv | grep -iE 'OTEL|OTLP|TRACING' || true
```

若走 Helm 直更（无 Argo 时）：

```bash
helm upgrade iot-learn infra/helm/iot-learn-lab -n iot-learn \
  -f infra/helm/iot-learn-lab/values.yaml \
  -f infra/helm/iot-learn-lab/values-minikube.yaml \
  -f infra/helm/iot-learn-lab/values-v1.yaml \
  --wait
# ConfigMap 变了但镜像 tag 未变时，仍建议：
kubectl -n iot-learn rollout restart deploy/command-dispatch-service
kubectl -n iot-learn rollout restart deploy/device-report-consumer
kubectl -n iot-learn rollout restart deploy/device-report-service
# 或对应 Rollout restart
```

- [ ] **Step 3: 打一枪同步接口**

```bash
curl -s -o /dev/null -w "%{http_code}\n" \
  -H "Host: device-report.iot-learn.local" \
  -X POST "http://$(minikube ip)/api/v1/devices/k8-trace-1/reports" \
  -H "Content-Type: application/json" \
  -d '{"payload":{"temp":1,"source":"k8"}}'
```

- [ ] **Step 4: Jaeger UI → Service `device-report-service`（或实际 spring.application.name）→ Find Traces**

Expected: 至少出现 HTTP server span；无数据则查 Task 6 排障表。

---

### Task 5: 验证 Feign 与 Kafka 链路

- [ ] **Step 1: Feign 路径**

```bash
curl -s -H "Host: device-report.iot-learn.local" \
  -X POST "http://$(minikube ip)/api/v1/devices/k8-feign-1/reports-with-dispatch" \
  -H "Content-Type: application/json" \
  -d '{"payload":{"temp":2,"source":"k8-feign"}}'
```

Jaeger 期望 span 树含 report + dispatch（同一 `traceId`）。

- [ ] **Step 2: Async / Kafka（尽力）**

```bash
curl -s -H "Host: device-report.iot-learn.local" \
  -X POST "http://$(minikube ip)/api/v1/devices/k8-async-1/reports-async" \
  -H "Content-Type: application/json" \
  -d '{"payload":{"temp":3,"source":"k8-async"}}'
```

期望：producer 侧有 span；consumer 侧有独立或关联 trace（Kafka 传播依赖 header / observation，若未联通，runbook 如实记录「已知限制」即可，不阻塞结业）。

- [ ] **Step 3: 截图或文字记录 1 条完整 Feign trace 到 runbook**

---

### Task 6: 场景脚本 + Tracing Runbook

**Files:**

- Create: `iot-learn-lab/docs/stage2-tracing-runbook.md`
- Create: `iot-learn-lab/scripts/stage2/scenario-k8-jaeger-trace.sh`
- Modify: `iot-learn-lab/docs/stage2-interview-notes.md`
- Modify: `iot-learn-lab/README.md`（进度 W8）

- [ ] **Step 1: Runbook 最少章节**

1. 架构图（Pod → OTLP → Jaeger）  
2. 启动 / 停止 Jaeger  
3. 采样与 endpoint 配置  
4. 如何在 UI 查 `reports-with-dispatch`  
5. 排障：无 trace、只有单服务、Kafka 断链  
6. 与 Metrics/Logs 如何对照排障（面试）

- [ ] **Step 2: 脚本最小断言**

- Jaeger UI 或 Query API 可达（`16686`）  
- 发一次 Feign 请求返回 2xx  
- （可选）调用 Jaeger API 搜 recent traces 非空  

```bash
# 示例：Jaeger API（路径随版本可能微调）
curl -sf "http://${JAEGER_HOST}:16686/api/services" | head -c 300
```

- [ ] **Step 3: 跑通 `K8 PASS`**

- [ ] **Step 4: Commit + push**

---

## W8 完成标准（Checklist）

- [ ] Jaeger UI 可打开；OTLP 4317/4318 监听
- [ ] 三服务镜像含 tracing 依赖；k8s 配置指向 `host.minikube.internal`
- [ ] Jaeger 中能看到 **device-report** 的 HTTP trace
- [ ] 至少一条 **report → Feign → dispatch** 同 traceId 的调用树
- [ ] （尽力）Kafka consumer 有 span；否则 runbook 写明限制
- [ ] `stage2-tracing-runbook.md` + `scenario-k8-jaeger-trace.sh` 就绪
- [ ] interview notes / README 已更新

---

## W8 面试话术速记

> 「Metrics 看聚合对不对、Logs 看单机细节、Traces 把一次请求在多个服务上的耗时串成树。我们用 Micrometer Tracing 桥到 OTel，经 OTLP 打到 Jaeger。学习环境采样率 1.0；生产会降采样。HTTP/Feign 传播靠 trace context；Kafka 要靠消息头传播，链路更容易断，需要单独打开 observation。」

---

## 常见坑

| 现象 | 可能原因 | 处理 |
|------|----------|------|
| UI 完全无服务 | 未导出 / endpoint 错 / 采样 0 | 查 env；probability=1.0；看应用启动日志 |
| 只有 report 没有 dispatch | Feign 未传播或 dispatch 未装 tracing | 确认两服务都有依赖与 exporter |
| Pod → 4318 超时 | host.minikube.internal / 防火墙 / Jaeger 未起 | 临时 Pod curl；检查 compose ports |
| 有 span 但 Kafka 断开 | 未开 observation / 无 header 传播 | 开 listener observation；runbook 记限制 |
| 改了 yml 镜像未重建 | 旧层无依赖 | 重新 `mvn package` + `image load` + 滚动 |
| Argo Synced 但行为旧 | ConfigMap 未变或 checksum 未触发 | 改 APP_/OTEL_ 触发滚动 |

---

## 下一步（W9 预告）

- GitHub Actions：`mvn verify` → build → push GHCR  
- tag 用 short SHA  
- **W10** 再把 `image.tag` 写回 Helm values，闭环 GitOps + Rollouts

**W9 实施计划文件（待写）：** `docs/superpowers/plans/YYYY-MM-DD-stage2-w9-github-actions.md`

---

## Spec 覆盖自检

| Spec 要求（Stage 2 W8） | 本计划 Task |
|-------------------------|-------------|
| Trace / Span / 三支柱理论 | 指南 + interview notes |
| micrometer-tracing-bridge-otel + OTLP | Task 2–3 |
| Jaeger all-in-one | Task 1 |
| POST /reports 全链路；Feign + Kafka | Task 4–5 |
| `stage2-tracing-runbook.md` | Task 6 |
| 场景脚本（本计划增补 K8） | Task 6 |

---

## 执行方式

**Plan complete and saved to `docs/superpowers/plans/2026-07-23-stage2-w8-jaeger.md`. Two execution options:**

1. **Subagent-Driven（推荐）** — 按 Task 派发子代理，每 Task 后 review  
2. **Inline Execution** — 本会话按 Task 1→6 连续执行；Checkpoint 建议在 Task 1（Jaeger UI）与 Task 4（首条 trace）后  

**Which approach?**
