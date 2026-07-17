# Stage 2 W2：三服务上集群 + Feign / Kafka 互通 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 **`command-dispatch-service`** 与 **`device-report-consumer`** 部署进 minikube；`device-report-service` 通过 **K8s Service DNS** 调用 Feign；同步上报（含 dispatch）与异步 Kafka 路径均在 Pod 内跑通。

**Architecture:** 三个 Java Pod 同属 `iot-learn` Namespace。Feign **不启用 Nacos 发现**（延续 W1 混合部署策略），用 ConfigMap 注入 `DISPATCH_BASE_URL=http://command-dispatch-service:8767`。Kafka / PostgreSQL / Redis 仍在 WSL Docker；修正 Kafka **`advertised.listeners`**，使 Pod 经 `host.minikube.internal:9092`（或 `192.168.19.64:9092`）完成 metadata 回连。W2 不做 Ingress（留给 W3）。

**Tech Stack:** Java 21, Spring Boot 3.3.5, OpenFeign, Kafka 3.9, minikube (docker driver), kubectl, 现有 WSL 中间件栈

**Spec 来源:** `docs/superpowers/specs/2026-07-13-stage2-k8s-gitops-design.md`（W2 段）

**前置知识指南:** `docs/superpowers/guides/2026-07-16-stage2-w2-service-dns-kafka.md`

**前置条件（W1 已完成）:**

- [x] `minikube` Running，`kubectl get nodes` Ready
- [x] 三个模块 Dockerfile 已存在；`device-report-service` 已 `image load` 并可 `1/1 Running`
- [x] `application-k8s.yml`（device-report）+ `infra/k8s/device-report/*` + `scripts/stage2/env.sh` + K1 脚本
- [x] Pod → DB/Redis 用 `host.minikube.internal`；Nacos 在 k8s profile 下 `enabled: false`
- [ ] Kafka 容器运行中（`docker ps` 可见 `kafka-learn` 或等价名）
- [ ] W1 两镜像若未 load：本计划 Task 3 会 load

**时间预算:** 1 周 × 10–15h

**W2 边界:**

| W2 做 | W2 不做 |
|-------|---------|
| 部署 dispatch + consumer | Ingress（W3） |
| Feign → K8s Service DNS | Nacos 服务发现（仍关闭） |
| Kafka 异步路径 Pod 内跑通 | Helm / Argo（W4+） |
| 修正 Kafka advertised.listeners | Prometheus 抓取 K8s target（W3） |
| `scenario-k2-three-services.sh` | Jaeger / CI/CD |

---

## W2 拓扑（读完再动手）

```text
┌─ minikube namespace=iot-learn ─────────────────────────────────────────┐
│                                                                         │
│  device-report-service:8765                                             │
│    DISPATCH_BASE_URL → http://command-dispatch-service:8767  (ClusterIP)│
│    KAFKA_BOOTSTRAP   → host.minikube.internal:9092                      │
│         │ Feign                                                         │
│         ▼                                                               │
│  command-dispatch-service:8767                                          │
│                                                                         │
│  device-report-consumer:8768                                            │
│    消费 topic device-report-events → PostgreSQL                         │
└────────────────────────────┬────────────────────────────────────────────┘
                             │ host.minikube.internal / 192.168.19.64
┌────────────────────────────▼────────────────────────────────────────────┐
│  WSL Docker                                                              │
│  postgres:5432 · redis:6379 · kafka:9092 · nacos:8848（W2 仍不依赖）   │
└─────────────────────────────────────────────────────────────────────────┘
```

**API 路径（与 Phase 3/5 一致；勿用 K1 脚本里错误的 `/api/v1/reports`）：**

| 场景 | Method / Path | 期望 |
|------|---------------|------|
| 同步上报 | `POST /api/v1/devices/{id}/reports` | 201 |
| Feign 联动 | `POST /api/v1/devices/{id}/reports-with-dispatch` | 201，含 dispatch ack |
| 异步削峰 | `POST /api/v1/devices/{id}/reports-async` | 202；consumer 写入 PG |

---

## 文件结构（W2 新增 / 修改）

```text
iot-learn-lab/
├── command-dispatch-service/
│   └── src/main/resources/
│       └── application-k8s.yml          # 新建
├── device-report-consumer/
│   └── src/main/resources/
│       └── application-k8s.yml          # 新建
├── device-report-service/
│   └── src/main/resources/
│       └── application-k8s.yml          # 修改：Feign + Kafka 默认值
├── infra/
│   ├── kafka/
│   │   └── docker-compose-kafka.yml     # 修改：advertised.listeners
│   └── k8s/
│       ├── README.md                    # 追加 W2 章节
│       ├── device-report/
│       │   └── configmap-env.yaml       # 追加 DISPATCH / KAFKA
│       ├── command-dispatch/
│       │   ├── configmap-env.yaml
│       │   ├── deployment.yaml
│       │   └── service.yaml
│       └── device-report-consumer/
│           ├── configmap-env.yaml
│           ├── deployment.yaml
│           └── service.yaml
├── scripts/stage2/
│   ├── env.sh                           # 可选补充说明
│   └── scenario-k2-three-services.sh    # 新建
└── docs/
    └── stage2-interview-notes.md        # 新建或追加 W2

docs/superpowers/
├── plans/2026-07-16-stage2-w2-three-services.md   # 本文件
└── guides/2026-07-16-stage2-w2-service-dns-kafka.md
```

---

## 学习场景 K2：三服务互通（W2 Day 5–6）

| 项 | 内容 |
|----|------|
| **操作** | 三 Pod Ready → port-forward report → sync / with-dispatch / async |
| **预期** | health UP；with-dispatch 201 且非 fallback；async 202 且 PG 有新行 |
| **面试** | 「同 Namespace 下 Service DNS 怎么拼？」「为什么 Kafka bootstrap 通了仍连不上？」 |

---

### Task 1: 修正 Kafka advertised.listeners（混合部署必做）

**Files:**
- Modify: `iot-learn-lab/infra/kafka/docker-compose-kafka.yml`

> **为什么：** 客户端先连 bootstrap，再按 broker 返回的 **advertised** 地址建真正连接。若 advertised 仍是 `localhost:9092`，Pod 内的 `localhost` 是容器自己 → 生产者/消费者必挂。Windows / WSL 客户端也更稳妥地使用 WSL eth0 IP。

- [ ] **Step 1: 改 `KAFKA_ADVERTISED_LISTENERS`**

将：

```yaml
KAFKA_ADVERTISED_LISTENERS: "PLAINTEXT://kafka:19092,PLAINTEXT_HOST://localhost:9092"
```

改为（`192.168.19.64` 以你环境 `ip -4 addr show eth0` 为准）：

```yaml
# 宿主机 / minikube Pod 共用：WSL eth0 IP（勿用 localhost，Pod 会连自己）
KAFKA_ADVERTISED_LISTENERS: "PLAINTEXT://kafka:19092,PLAINTEXT_HOST://192.168.19.64:9092"
```

文件顶部注释同步改为说明「Pod 与 Windows 均用 `192.168.19.64:9092`」。

- [ ] **Step 2: 重建 Kafka 容器**

```bash
cd iot-learn-lab/infra/kafka
docker compose up -d --force-recreate
docker exec kafka-learn /opt/kafka/bin/kafka-broker-api-versions.sh \
  --bootstrap-server 192.168.19.64:9092 | head -5
```

Expected: 无 Connection refused；能打印 API versions

- [ ] **Step 3: 从 minikube 节点探测端口**

```bash
minikube ssh -- nc -zv host.minikube.internal 9092
minikube ssh -- nc -zv 192.168.19.64 9092
```

Expected: 至少一个 `succeeded`（两者通常都能通）

- [ ] **Step 4: Commit（若你要求提交时再执行）**

```bash
git add iot-learn-lab/infra/kafka/docker-compose-kafka.yml
git commit -m "$(cat <<'EOF'
fix(kafka): advertise WSL IP so minikube pods can reconnect

EOF
)"
```

---

### Task 2: 三个模块的 `application-k8s.yml`

**Files:**
- Create: `iot-learn-lab/command-dispatch-service/src/main/resources/application-k8s.yml`
- Create: `iot-learn-lab/device-report-consumer/src/main/resources/application-k8s.yml`
- Modify: `iot-learn-lab/device-report-service/src/main/resources/application-k8s.yml`

- [ ] **Step 1: `command-dispatch-service` 的 `application-k8s.yml`**

```yaml
# 激活方式：SPRING_PROFILES_ACTIVE=k8s
# 无 DB / Redis / Nacos；仅启用探针端点
management:
  endpoints:
    web:
      exposure:
        include: health,info,prometheus,metrics
  endpoint:
    health:
      probes:
        enabled: true
```

- [ ] **Step 2: `device-report-consumer` 的 `application-k8s.yml`**

```yaml
# 激活方式：SPRING_PROFILES_ACTIVE=k8s
spring:
  datasource:
    url: jdbc:postgresql://${DB_HOST:host.minikube.internal}:${DB_PORT:5432}/iot_learn?options=-c%20TimeZone=Asia/Shanghai
    username: ${DB_USERNAME:postgres}
    password: ${DB_PASSWORD:postgres}
  cloud:
    nacos:
      discovery:
        enabled: false
        server-addr: ${NACOS_ADDR:192.168.19.64:8848}
  kafka:
    bootstrap-servers: ${KAFKA_BOOTSTRAP:host.minikube.internal:9092}

management:
  endpoints:
    web:
      exposure:
        include: health,info,prometheus,metrics
  endpoint:
    health:
      probes:
        enabled: true
```

- [ ] **Step 3: 扩展 `device-report-service` 的 `application-k8s.yml`**

在现有文件末尾（`management` 段之后）追加 Kafka 与 Feign URL 覆盖；保留 W1 的 Nacos `enabled: false`。完整目标内容：

```yaml
# 激活方式：SPRING_PROFILES_ACTIVE=k8s
# 所有 host 通过环境变量注入，不在镜像内写死 IP
#
# W2：Feign 用 K8s Service DNS；Kafka 走宿主机 advertised IP
# Nacos：k8s profile 仍关闭（混合部署 gRPC 宣告问题见 infra/k8s/README）
spring:
  datasource:
    url: jdbc:postgresql://${DB_HOST:host.minikube.internal}:${DB_PORT:5432}/iot_learn?options=-c%20TimeZone=Asia/Shanghai
    username: ${DB_USERNAME:postgres}
    password: ${DB_PASSWORD:postgres}
  data:
    redis:
      host: ${REDIS_HOST:host.minikube.internal}
      port: ${REDIS_PORT:6379}
      database: 1
  cloud:
    nacos:
      discovery:
        enabled: false
        server-addr: ${NACOS_ADDR:192.168.19.64:8848}
      config:
        enabled: false
        server-addr: ${NACOS_ADDR:192.168.19.64:8848}
    sentinel:
      transport:
        dashboard: ${SENTINEL_DASHBOARD:host.minikube.internal:8858}
  kafka:
    bootstrap-servers: ${KAFKA_BOOTSTRAP:host.minikube.internal:9092}

# Feign：@FeignClient(url=...) 读取此属性；同 Namespace 短名即可
dispatch:
  base-url: ${DISPATCH_BASE_URL:http://command-dispatch-service:8767}

management:
  endpoints:
    web:
      exposure:
        include: health,info,prometheus,metrics
  endpoint:
    health:
      probes:
        enabled: true
```

- [ ] **Step 4: 本地编译确认资源打进 jar**

```bash
cd iot-learn-lab
mvn -B -pl device-report-service,command-dispatch-service,device-report-consumer -am package -DskipTests
jar tf device-report-service/target/device-report-service-*.jar | grep application-k8s
jar tf command-dispatch-service/target/command-dispatch-service-*.jar | grep application-k8s
jar tf device-report-consumer/target/device-report-consumer-*.jar | grep application-k8s
```

Expected: 三个 jar 均列出 `BOOT-INF/classes/application-k8s.yml`

---

### Task 3: 重建并 load 三张镜像

**Files:**（无新文件；沿用现有 Dockerfile）

- [ ] **Step 1: 在 `iot-learn-lab` 根目录 build**

```bash
cd iot-learn-lab
docker build -f device-report-service/Dockerfile -t device-report-service:0.1.0-SNAPSHOT .
docker build -f command-dispatch-service/Dockerfile -t command-dispatch-service:0.1.0-SNAPSHOT .
docker build -f device-report-consumer/Dockerfile -t device-report-consumer:0.1.0-SNAPSHOT .
```

Expected: 三个 `exporting to image` 成功

- [ ] **Step 2: 同 tag 覆盖时先删节点旧镜像再 load**

```bash
source scripts/stage2/env.sh

# 若旧 Deployment 占用镜像，可先不删 Deployment；仅换镜像时：
minikube image rm device-report-service:0.1.0-SNAPSHOT || true
minikube image rm command-dispatch-service:0.1.0-SNAPSHOT || true
minikube image rm device-report-consumer:0.1.0-SNAPSHOT || true

minikube image load device-report-service:0.1.0-SNAPSHOT
minikube image load command-dispatch-service:0.1.0-SNAPSHOT
minikube image load device-report-consumer:0.1.0-SNAPSHOT

minikube ssh -- docker images | grep -E 'device-report|command-dispatch'
```

Expected: 三行镜像均存在

---

### Task 4: 更新 device-report ConfigMap（Feign + Kafka）

**Files:**
- Modify: `iot-learn-lab/infra/k8s/device-report/configmap-env.yaml`

- [ ] **Step 1: 写入完整 ConfigMap**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: device-report-middleware
  namespace: iot-learn
data:
  DB_HOST: "host.minikube.internal"
  DB_PORT: "5432"
  DB_USERNAME: "postgres"
  DB_PASSWORD: "postgres"
  REDIS_HOST: "host.minikube.internal"
  REDIS_PORT: "6379"
  NACOS_ADDR: "192.168.19.64:8848"
  SENTINEL_DASHBOARD: "host.minikube.internal:8858"
  SPRING_PROFILES_ACTIVE: "k8s"
  # W2：同 Namespace Service 短名；FQDN 等价于
  # http://command-dispatch-service.iot-learn.svc.cluster.local:8767
  DISPATCH_BASE_URL: "http://command-dispatch-service:8767"
  # bootstrap 可用 host.minikube.internal；真正建连依赖 Task 1 的 advertised IP
  KAFKA_BOOTSTRAP: "host.minikube.internal:9092"
```

- [ ] **Step 2: apply 并滚动重启 report**

```bash
kubectl apply -f iot-learn-lab/infra/k8s/device-report/configmap-env.yaml
kubectl rollout restart deployment/device-report-service -n iot-learn
kubectl rollout status deployment/device-report-service -n iot-learn --timeout=180s
```

Expected: `successfully rolled out`

> ConfigMap 变更**不会**自动注入已运行容器；必须 restart / 重建 Pod。

---

### Task 5: command-dispatch-service 的 K8s 清单

**Files:**
- Create: `iot-learn-lab/infra/k8s/command-dispatch/configmap-env.yaml`
- Create: `iot-learn-lab/infra/k8s/command-dispatch/deployment.yaml`
- Create: `iot-learn-lab/infra/k8s/command-dispatch/service.yaml`

- [ ] **Step 1: `configmap-env.yaml`**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: command-dispatch-middleware
  namespace: iot-learn
data:
  SPRING_PROFILES_ACTIVE: "k8s"
```

- [ ] **Step 2: `deployment.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: command-dispatch-service
  namespace: iot-learn
  labels:
    app: command-dispatch-service
spec:
  replicas: 1
  selector:
    matchLabels:
      app: command-dispatch-service
  template:
    metadata:
      labels:
        app: command-dispatch-service
        version: v1
    spec:
      containers:
        - name: command-dispatch-service
          image: command-dispatch-service:0.1.0-SNAPSHOT
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8767
              name: http
          envFrom:
            - configMapRef:
                name: command-dispatch-middleware
          readinessProbe:
            httpGet:
              path: /actuator/health/readiness
              port: 8767
            initialDelaySeconds: 20
            periodSeconds: 10
            failureThreshold: 6
          livenessProbe:
            httpGet:
              path: /actuator/health/liveness
              port: 8767
            initialDelaySeconds: 40
            periodSeconds: 20
          resources:
            requests:
              memory: "256Mi"
              cpu: "100m"
            limits:
              memory: "512Mi"
              cpu: "500m"
```

- [ ] **Step 3: `service.yaml`**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: command-dispatch-service
  namespace: iot-learn
  labels:
    app: command-dispatch-service
spec:
  type: ClusterIP
  selector:
    app: command-dispatch-service
  ports:
    - name: http
      port: 8767
      targetPort: 8767
```

- [ ] **Step 4: apply 并等待 Ready**

```bash
kubectl apply -f iot-learn-lab/infra/k8s/command-dispatch/configmap-env.yaml
kubectl apply -f iot-learn-lab/infra/k8s/command-dispatch/deployment.yaml
kubectl apply -f iot-learn-lab/infra/k8s/command-dispatch/service.yaml
kubectl rollout status deployment/command-dispatch-service -n iot-learn --timeout=180s
kubectl get svc,pods -n iot-learn -l app=command-dispatch-service
```

Expected: Service `command-dispatch-service` ClusterIP；Pod `1/1 Running`

- [ ] **Step 5: 集群内 DNS 自检（从 report Pod）**

```bash
kubectl exec -n iot-learn deploy/device-report-service -- \
  wget -qO- --timeout=5 http://command-dispatch-service:8767/actuator/health || true
```

Expected: 含 `"status":"UP"`（若镜像无 wget，改用下方 port-forward 自检）

```bash
kubectl port-forward -n iot-learn svc/command-dispatch-service 8767:8767 &
sleep 2
curl -sf http://127.0.0.1:8767/actuator/health
kill %1 2>/dev/null || true
```

---

### Task 6: device-report-consumer 的 K8s 清单

**Files:**
- Create: `iot-learn-lab/infra/k8s/device-report-consumer/configmap-env.yaml`
- Create: `iot-learn-lab/infra/k8s/device-report-consumer/deployment.yaml`
- Create: `iot-learn-lab/infra/k8s/device-report-consumer/service.yaml`

- [ ] **Step 1: `configmap-env.yaml`**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: device-report-consumer-middleware
  namespace: iot-learn
data:
  DB_HOST: "host.minikube.internal"
  DB_PORT: "5432"
  DB_USERNAME: "postgres"
  DB_PASSWORD: "postgres"
  NACOS_ADDR: "192.168.19.64:8848"
  SPRING_PROFILES_ACTIVE: "k8s"
  KAFKA_BOOTSTRAP: "host.minikube.internal:9092"
  KAFKA_TOPIC: "device-report-events"
  KAFKA_CONSUMER_GROUP_ID: "device-report-consumer-group-k8s"
```

> `KAFKA_CONSUMER_GROUP_ID` 使用独立 group，避免与 Windows IDEA 本地 consumer 抢同一分区 offset（学习环境更清晰）。

- [ ] **Step 2: `deployment.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: device-report-consumer
  namespace: iot-learn
  labels:
    app: device-report-consumer
spec:
  replicas: 1
  selector:
    matchLabels:
      app: device-report-consumer
  template:
    metadata:
      labels:
        app: device-report-consumer
        version: v1
    spec:
      containers:
        - name: device-report-consumer
          image: device-report-consumer:0.1.0-SNAPSHOT
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8768
              name: http
          envFrom:
            - configMapRef:
                name: device-report-consumer-middleware
          readinessProbe:
            httpGet:
              path: /actuator/health/readiness
              port: 8768
            initialDelaySeconds: 30
            periodSeconds: 10
            failureThreshold: 6
          livenessProbe:
            httpGet:
              path: /actuator/health/liveness
              port: 8768
            initialDelaySeconds: 60
            periodSeconds: 20
          resources:
            requests:
              memory: "512Mi"
              cpu: "250m"
            limits:
              memory: "1Gi"
              cpu: "1000m"
```

- [ ] **Step 3: `service.yaml`**（便于 port-forward / 后续监控；consumer 不强制被 Feign 调用）

```yaml
apiVersion: v1
kind: Service
metadata:
  name: device-report-consumer
  namespace: iot-learn
  labels:
    app: device-report-consumer
spec:
  type: ClusterIP
  selector:
    app: device-report-consumer
  ports:
    - name: http
      port: 8768
      targetPort: 8768
```

- [ ] **Step 4: apply 并排查 Kafka**

```bash
kubectl apply -f iot-learn-lab/infra/k8s/device-report-consumer/configmap-env.yaml
kubectl apply -f iot-learn-lab/infra/k8s/device-report-consumer/deployment.yaml
kubectl apply -f iot-learn-lab/infra/k8s/device-report-consumer/service.yaml
kubectl rollout status deployment/device-report-consumer -n iot-learn --timeout=180s
kubectl logs -n iot-learn deploy/device-report-consumer --tail=80
```

Expected: `1/1 Running`；日志无反复 `Connection to node -1 ... localhost/127.0.0.1:9092 failed`

**若仍连 localhost：** 回到 Task 1 确认 advertised 已是 `192.168.19.64:9092`，并 `kubectl rollout restart deployment/device-report-consumer -n iot-learn`。

---

### Task 7: 场景 K2 验证脚本

**Files:**
- Create: `iot-learn-lab/scripts/stage2/scenario-k2-three-services.sh`
- Modify（可选）: `iot-learn-lab/scripts/stage2/scenario-k1-k8s-baseline.sh` — 修正错误路径 `/api/v1/reports` → `/api/v1/devices/.../reports`

- [ ] **Step 1: 创建 `scenario-k2-three-services.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "${SCRIPT_DIR}/env.sh"

NS="${K8S_NAMESPACE}"
REPORT_SVC="device-report-service"
LOCAL_PORT=8765
TS="$(date +%s)"

echo "== K2: three services on minikube =="

for dep in device-report-service command-dispatch-service device-report-consumer; do
  kubectl rollout status "deployment/${dep}" -n "$NS" --timeout=120s
done

kubectl get pods -n "$NS" -o wide

kubectl port-forward -n "$NS" "svc/${REPORT_SVC}" "${LOCAL_PORT}:8765" &
PF_PID=$!
trap 'kill $PF_PID 2>/dev/null || true' EXIT
sleep 3

echo "-- health (report) --"
curl -sf "http://127.0.0.1:${LOCAL_PORT}/actuator/health" | head -c 300
echo

echo "-- sync POST .../reports --"
DEVICE_SYNC="k2-sync-${TS}"
curl -sf -X POST "http://127.0.0.1:${LOCAL_PORT}/api/v1/devices/${DEVICE_SYNC}/reports" \
  -H "Content-Type: application/json" \
  -d "{\"payload\":{\"temp\":21,\"source\":\"k2-sync\"}}"
echo

echo "-- Feign POST .../reports-with-dispatch --"
DEVICE_FEIGN="k2-feign-${TS}"
RESP_FEIGN="$(curl -sf -X POST \
  "http://127.0.0.1:${LOCAL_PORT}/api/v1/devices/${DEVICE_FEIGN}/reports-with-dispatch" \
  -H "Content-Type: application/json" \
  -d "{\"payload\":{\"temp\":22,\"source\":\"k2-feign\"}}")"
echo "$RESP_FEIGN"
# 成功时应带上 dispatch 结果；fallback 时通常有降级标记或缺少正常 ack
echo "$RESP_FEIGN" | grep -qiE 'fallback|degraded|CIRCUIT' \
  && { echo "K2 FAIL: Feign 疑似走了 fallback，检查 DISPATCH_BASE_URL 与 dispatch Pod"; exit 1; } \
  || true

echo "-- async POST .../reports-async --"
DEVICE_ASYNC="k2-async-${TS}"
RESP_ASYNC="$(curl -sf -X POST \
  "http://127.0.0.1:${LOCAL_PORT}/api/v1/devices/${DEVICE_ASYNC}/reports-async" \
  -H "Content-Type: application/json" \
  -d "{\"payload\":{\"temp\":23,\"source\":\"k2-async\"}}")"
echo "$RESP_ASYNC"
echo "$RESP_ASYNC" | grep -q ACCEPTED

echo "-- wait consumer (5s) --"
sleep 5
kubectl logs -n "$NS" deploy/device-report-consumer --tail=30 | tee /tmp/k2-consumer-tail.txt
grep -qiE "${DEVICE_ASYNC}|Received kafka|batch" /tmp/k2-consumer-tail.txt \
  || echo "WARN: 日志未明显命中 deviceId；请到 PostgreSQL 查 device_report 表确认"

echo
echo "K2 PASS: sync + Feign + async 路径基本打通"
```

- [ ] **Step 2: 赋予执行权限并运行**

```bash
chmod +x iot-learn-lab/scripts/stage2/scenario-k2-three-services.sh
iot-learn-lab/scripts/stage2/scenario-k2-three-services.sh
```

Expected: 输出 `K2 PASS`

- [ ] **Step 3（可选）: 修正 K1 脚本路径**

将 `scenario-k1-k8s-baseline.sh` 中：

```bash
curl -sf -X POST "http://127.0.0.1:${LOCAL_PORT}/api/v1/reports" \
  -H "Content-Type: application/json" \
  -d "{\"deviceId\":\"${DEVICE_ID}\",\"payload\":{\"temp\":25}}"
```

改为：

```bash
curl -sf -X POST "http://127.0.0.1:${LOCAL_PORT}/api/v1/devices/${DEVICE_ID}/reports" \
  -H "Content-Type: application/json" \
  -d "{\"payload\":{\"temp\":25}}"
```

- [ ] **Step 4: PostgreSQL 抽查（WSL）**

```bash
docker exec -i postgres-alpine psql -U postgres -d iot_learn -c \
  "SELECT device_id, created_at FROM device_report WHERE device_id LIKE 'k2-%' ORDER BY created_at DESC LIMIT 10;"
```

Expected: 至少看到 `k2-sync-*` / `k2-async-*`（表名/列名若不同，按 `infra/postgres/create_table.sql` 调整）

---

### Task 8: README + 面试笔记

**Files:**
- Modify: `iot-learn-lab/infra/k8s/README.md`
- Create or Modify: `iot-learn-lab/docs/stage2-interview-notes.md`

- [ ] **Step 1: 在 README 追加「W2：三服务」章节**

```markdown
## W2：三服务 + Feign / Kafka

### 部署顺序

\`\`\`bash
source scripts/stage2/env.sh
# Task 1 已修正 Kafka advertised 后：
kubectl apply -f infra/k8s/device-report/configmap-env.yaml
kubectl apply -f infra/k8s/command-dispatch/
kubectl apply -f infra/k8s/device-report-consumer/
kubectl rollout restart deployment/device-report-service -n iot-learn
kubectl get pods -n iot-learn
\`\`\`

### 验证

\`\`\`bash
scripts/stage2/scenario-k2-three-services.sh
\`\`\`

### 服务发现口诀

| 方式 | W2 用法 |
|------|---------|
| K8s Service DNS | \`http://command-dispatch-service:8767\`（同 ns） |
| Nacos | k8s profile **关闭** |
| Feign url | \`DISPATCH_BASE_URL\` → \`dispatch.base-url\` |

### Kafka 踩坑

端口 \`nc\` 通 ≠ 客户端能用。必须看 **advertised.listeners** 是否为 Pod 可达地址（\`192.168.19.64:9092\`），不能是 \`localhost\`。
```

- [ ] **Step 2: 写入 / 追加 `stage2-interview-notes.md`**

```markdown
# Stage 2 面试复盘笔记

**日期：** 2026-07-13 起  
**架构：** 混合中间件（应用 K8s + 中间件 WSL Docker）

## W1 场景记录

| 场景 | 日期 | 通过？ | 关键现象 |
|------|------|--------|----------|
| K1 K8s 基线 | | ☑ | Pod Ready；port-forward health UP；同步上报 |

## W2 场景记录

| 场景 | 日期 | 通过？ | 关键现象 |
|------|------|--------|----------|
| K2 三服务互通 | | ☐ | Feign 201；async 202；consumer 消费成功 |

## W2 面试题自测

1. 同 Namespace 下访问 Service，DNS 短名怎么写？FQDN 呢？
2. 为什么 W2 不用 Nacos 做 Feign 发现，而用 `DISPATCH_BASE_URL`？
3. Kafka「bootstrap 能连、业务仍失败」通常卡在哪一步？
4. ConfigMap 改了环境变量，为什么还要 `rollout restart`？
5. consumer 为何单独设 `KAFKA_CONSUMER_GROUP_ID=...-k8s`？

## 踩坑记录

| 踩坑 | 原因 | 处理 |
|------|------|------|
| | | |
```

---

## W2 完成标准（Checklist）

- [ ] Kafka `advertised.listeners` 含 `192.168.19.64:9092`（非 localhost）
- [ ] 三个模块均有可用的 `application-k8s.yml`，镜像已 rebuild + load
- [ ] `command-dispatch-service`、`device-report-consumer` Deployment `1/1 Running`
- [ ] ConfigMap 含 `DISPATCH_BASE_URL` 与 `KAFKA_BOOTSTRAP`
- [ ] `scenario-k2-three-services.sh` 输出 `K2 PASS`
- [ ] `infra/k8s/README.md` 含 W2 部署与 Kafka 踩坑说明
- [ ] `stage2-interview-notes.md` W2 章节已填

---

## W2 面试话术速记

| 问题 | 答法 |
|------|------|
| Service DNS？ | 同 ns：`svc名:port`；跨 ns：`svc.ns.svc.cluster.local:port` |
| Feign 为何写死 URL？ | 混合部署下 Nacos gRPC 宣告易错；W2 用 K8s DNS 更稳；W6+ 可再对比 |
| Kafka advertised？ | bootstrap 只是入口；metadata 返回的地址必须对客户端可达 |
| 与 Phase 3 关系？ | 同一套 Feign/熔断代码；发现从「本机 localhost / Nacos」换成「集群 DNS」 |

---

## 常见踩坑

| 现象 | 原因 | 处理 |
|------|------|------|
| with-dispatch 走 fallback | `DISPATCH_BASE_URL` 仍是 localhost 或 Service 未建 | 查 ConfigMap；`kubectl get svc` |
| consumer CrashLoop / 连 localhost:9092 | Kafka advertised 未改 | Task 1 + restart consumer |
| ImagePullBackOff | 未 load 新镜像 | `minikube image load` |
| ConfigMap 改了不生效 | 未滚动 Pod | `kubectl rollout restart` |
| async 202 但 PG 无数据 | group 抢占 / topic 名不一致 / consumer 未 Ready | 看 consumer 日志；确认 `KAFKA_TOPIC` |
| report 调 dispatch 超时 | 跨 Namespace 或端口写错 | 确认同 `iot-learn` 且 port=8767 |

---

## 下一步（W3）

- `minikube addons enable ingress`；为 `device-report-service` 写 Ingress
- 外部 Prometheus 增加 K8s Pod / NodePort scrape
- 脚本：`scenario-k3-ingress-baseline.sh`
- 压测对比：IDEA 直连 vs Ingress 延迟

**W3 实施计划：** `docs/superpowers/plans/2026-07-16-stage2-w3-ingress-prometheus.md`  
**W3 前置指南：** `docs/superpowers/guides/2026-07-16-stage2-w3-ingress-prometheus.md`

---

## Spec 覆盖自检

| Spec 要求（Stage 2 W2 段） | 本计划 Task |
|---------------------------|-------------|
| 部署 command-dispatch | Task 5 |
| 部署 device-report-consumer | Task 6 |
| Feign → K8s Service DNS | Task 2、4、5 |
| 同步 + 异步路径跑通 | Task 7（K2） |
| `scenario-k2-three-services.sh` | Task 7 |
| Kafka 混合网络可达 | Task 1（隐式前置，Spec 网络约定） |

---

## 执行方式

**Plan complete and saved to `docs/superpowers/plans/2026-07-16-stage2-w2-three-services.md`. Two execution options:**

1. **Subagent-Driven（推荐）** — 按 Task 派发子代理，每 Task 后 review  
2. **Inline Execution** — 本会话按 Task 1→8 连续执行，Checkpoint 在 Task 5 后

**Which approach?**
