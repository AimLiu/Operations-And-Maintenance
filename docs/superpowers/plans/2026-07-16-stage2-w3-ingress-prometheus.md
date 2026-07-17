# Stage 2 W3：Ingress + 外部 Prometheus 联通 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 `device-report-service` 启用 **minikube Ingress** 作为集群入口；让 WSL Docker 里的 **外部 Prometheus** 通过 **NodePort** 抓到 K8s Pod 的 `/actuator/prometheus`；用脚本对比 **IDEA 直连 vs Ingress** 延迟基线。

**Architecture:** Ingress Controller（nginx addon）把 Host `device-report.iot-learn.local` 转到现有 ClusterIP/NodePort Service `device-report-service:8765`。Prometheus 仍跑在 WSL Docker（Phase 1–5 的 `prometheus-learn`），不进集群；通过固定 NodePort（`30765` / `30767`）经 `minikube ip` 抓取。W3 不做 Helm / Argo / ServiceMonitor（留给 W4+ / W11+）。

**Tech Stack:** minikube ingress addon, Kubernetes Ingress, NodePort Service, Prometheus static_configs, curl 延迟采样, 现有三服务 Deployment

**Spec 来源:** `docs/superpowers/specs/2026-07-13-stage2-k8s-gitops-design.md`（W3 段）

**前置知识指南:** `docs/superpowers/guides/2026-07-16-stage2-w3-ingress-prometheus.md`

**前置条件（W2 已完成）:**

- [x] 三服务 Deployment `1/1 Running`（report / dispatch / consumer）
- [x] Feign → `http://command-dispatch-service:8767`；Kafka advertised 非 localhost
- [x] `scenario-k2-three-services.sh` 可出 `K2 PASS`
- [ ] WSL 中 Prometheus 容器运行中（`docker ps` 可见 `prometheus-learn` 或等价名）
- [ ] （对照压测可选）Windows IDEA 仍可起 `device-report-service:8765`

**时间预算:** 1 周 × 10–15h

**W3 边界:**

| W3 做 | W3 不做 |
|-------|---------|
| `minikube addons enable ingress` + Ingress 规则 | Helm Chart（W4） |
| NodePort 暴露 metrics 给外部 Prometheus | Prometheus Operator / ServiceMonitor |
| K3：Ingress 健康 + 上报 + 延迟对照 | APISIX upstream 改指向 Ingress（W4–W7） |
| `scenario-k3-ingress-baseline.sh` | Argo / Jaeger / CI |

---

## W3 拓扑（读完再动手）

```text
┌─ 客户端（WSL / Windows）─────────────────────────────────────────────┐
│  curl -H "Host: device-report.iot-learn.local" http://$(minikube ip)/  │
│  或 minikube tunnel → http://device-report.iot-learn.local/            │
└───────────────────────────────┬──────────────────────────────────────┘
                                │ Ingress (nginx addon :80)
┌─ minikube namespace=iot-learn ─▼──────────────────────────────────────┐
│  Ingress → Service device-report-service:8765 (NodePort 30765)         │
│       → device-report Pod                                              │
│            ├─ Feign → command-dispatch-service:8767 (NodePort 30767)   │
│            └─ Kafka → host.minikube.internal:9092                      │
└───────────────────────────────┬────────────────────────────────────────┘
                                │ scrape $(minikube ip):30765 / 30767
┌───────────────────────────────▼────────────────────────────────────────┐
│  WSL Docker: prometheus-learn:9090 → Grafana（沿用 Phase 1 Dashboard） │
│  postgres / redis / kafka / nacos / APISIX（W3 不改入口策略）          │
└────────────────────────────────────────────────────────────────────────┘
```

**入口对照（W3 要建立的心智模型）：**

| 方式 | URL 示例 | 用途 |
|------|----------|------|
| port-forward（W1–W2） | `http://127.0.0.1:8765/...` | 调试最快 |
| Ingress + Host 头 | `http://$(minikube ip)/...` + `Host: device-report.iot-learn.local` | 不依赖 tunnel |
| Ingress + tunnel | `http://device-report.iot-learn.local/...` | 接近真实域名访问 |
| IDEA 直连 | `http://192.168.16.1:8765/...`（WSL→Windows） | Phase 延迟对照基线 |
| Prometheus | `http://$(minikube ip):30765/actuator/prometheus` | 外部 scrape |

---

## 文件结构（W3 新增 / 修改）

```text
iot-learn-lab/
├── infra/
│   ├── k8s/
│   │   ├── README.md                              # 追加 W3 章节
│   │   ├── device-report/
│   │   │   ├── service.yaml                       # 改：ClusterIP → NodePort 30765
│   │   │   └── ingress.yaml                       # 新建
│   │   └── command-dispatch/
│   │       └── service.yaml                       # 改：NodePort 30767（给 Prometheus）
│   └── prometheus/
│       └── scrape-device-report.yml               # 追加 k8s jobs
├── scripts/stage2/
│   ├── env.sh                                     # 追加 INGRESS_HOST / NODEPORT 变量
│   └── scenario-k3-ingress-baseline.sh            # 新建
└── docs/
    └── stage2-interview-notes.md                  # 追加 W3

docs/superpowers/
├── plans/2026-07-16-stage2-w3-ingress-prometheus.md   # 本文件
└── guides/2026-07-16-stage2-w3-ingress-prometheus.md
```

---

## 学习场景 K3：Ingress 基线 + Prometheus（W3 Day 4–6）

| 项 | 内容 |
|----|------|
| **操作** | Ingress Ready → Host 头访问 health/上报 → Prometheus targets UP → 延迟对照 |
| **预期** | Ingress ADDRESS 非空（或 tunnel 可用）；health UP；sync 201；`device-report-k8s` target UP；脚本输出 `K3 PASS` |
| **面试** | 「Ingress 和 Service 谁负责 L7？」「集群外 Prometheus 怎么抓 Pod？」「为什么不用 ServiceMonitor？」 |

---

### Task 1: 启用 Ingress addon 并确认 Controller

**Files:**（无仓库文件；集群侧）

- [ ] **Step 1: 启用 addon**

```bash
minikube addons enable ingress
minikube addons enable metrics-server   # 若 W1 已开可跳过
kubectl get pods -n ingress-nginx
```

Expected: `ingress-nginx-controller-...` 为 `1/1 Running`（首次可能需 1–2 分钟拉镜像）

- [ ] **Step 2: 记录 minikube IP**

```bash
minikube ip
# 示例输出：192.168.49.2
```

把该 IP 记入本机笔记；后续 Host 头访问与 Prometheus scrape 都用它。
- 我在WSL中执行该命令拿到的结果是：192.168.49.2

- [ ] **Step 3: 确认三服务仍 Ready**

```bash
source iot-learn-lab/scripts/stage2/env.sh
kubectl get pods,svc -n iot-learn
```

Expected: 三个 Deployment 对应 Pod `1/1 Running`

---

### Task 2: Service 改为 NodePort（Ingress 后端 + Prometheus 入口）

**Files:**
- Modify: `iot-learn-lab/infra/k8s/device-report/service.yaml`
- Modify: `iot-learn-lab/infra/k8s/command-dispatch/service.yaml`

> **为什么改 NodePort：** Ingress 仍可把后端指到同名 Service（NodePort ⊃ ClusterIP）。同时固定 `nodePort`，让集群外 Prometheus 用 `$(minikube ip):30765` 稳定 scrape，无需每天 `kubectl port-forward`。

- [ ] **Step 1: 更新 `device-report/service.yaml`**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: device-report-service
  namespace: iot-learn
  labels:
    app: device-report-service
spec:
  type: NodePort
  selector:
    app: device-report-service
  ports:
    - name: http
      port: 8765
      targetPort: 8765
      nodePort: 30765
```

- [ ] **Step 2: 更新 `command-dispatch/service.yaml`**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: command-dispatch-service
  namespace: iot-learn
  labels:
    app: command-dispatch-service
spec:
  type: NodePort
  selector:
    app: command-dispatch-service
  ports:
    - name: http
      port: 8767
      targetPort: 8767
      nodePort: 30767
```

> consumer（8768）W3 **不强制** NodePort；需要时再加 `30768`。

- [ ] **Step 3: apply 并验证端口**

```bash
kubectl apply -f iot-learn-lab/infra/k8s/device-report/service.yaml
kubectl apply -f iot-learn-lab/infra/k8s/command-dispatch/service.yaml
kubectl get svc -n iot-learn
MINIKUBE_IP="$(minikube ip)"
curl -sf "http://${MINIKUBE_IP}:30765/actuator/health" | head -c 200
echo
curl -sf "http://${MINIKUBE_IP}:30767/actuator/health" | head -c 200
echo
```

Expected: Service 显示 `30765` / `30767`；两段 health 含 `"status":"UP"`（或 `{"status":"UP"...}`）

---

### Task 3: 创建 Ingress 清单

**Files:**
- Create: `iot-learn-lab/infra/k8s/device-report/ingress.yaml`

- [ ] **Step 1: 写入 Ingress**

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: device-report-ingress
  namespace: iot-learn
  labels:
    app: device-report-service
  annotations:
    # minikube ingress addon = ingress-nginx
    nginx.ingress.kubernetes.io/proxy-body-size: "2m"
spec:
  ingressClassName: nginx
  rules:
    - host: device-report.iot-learn.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: device-report-service
                port:
                  number: 8765
```

- [ ] **Step 2: apply 并等待 ADDRESS**

```bash
kubectl apply -f iot-learn-lab/infra/k8s/device-report/ingress.yaml
kubectl get ingress -n iot-learn -w
# Ctrl+C 退出 watch；期望 ADDRESS 列出现 minikube IP（如 192.168.49.2）
kubectl describe ingress device-report-ingress -n iot-learn
```

Expected: `Rules` 指向 `device-report-service:8765`；无长时间 `Backend not found`

- [ ] **Step 3: 用 Host 头验证（无需改 hosts / 无需 tunnel）**

```bash
MINIKUBE_IP="$(minikube ip)"
HOST="device-report.iot-learn.local"

curl -sf -H "Host: ${HOST}" "http://${MINIKUBE_IP}/actuator/health" | head -c 300
echo

TS="$(date +%s)"
curl -sf -H "Host: ${HOST}" -X POST \
  "http://${MINIKUBE_IP}/api/v1/devices/k3-ingress-${TS}/reports" \
  -H "Content-Type: application/json" \
  -d "{\"payload\":{\"temp\":30,\"source\":\"k3-ingress\"}}"
echo
```

Expected: health UP；POST 返回 201 风格 JSON（脚本用 `-sf`，失败会非 0）

- [ ] **Step 4（可选）：tunnel + /etc/hosts 域名访问**

```bash
# 终端 A（需保持运行；Linux/WSL 可能提示权限）
minikube tunnel

# 终端 B：把域名指到 127.0.0.1（tunnel 常见模式）或 minikube IP
# WSL 示例（tunnel 时多用 127.0.0.1）：
# echo "127.0.0.1 device-report.iot-learn.local" | sudo tee -a /etc/hosts

curl -sf "http://device-report.iot-learn.local/actuator/health" | head -c 200
echo
```

> 学习环境 **以 Step 3 Host 头为准** 即可通过 K3；tunnel 是加分项。

---

### Task 4: 外部 Prometheus 增加 K8s scrape targets

**Files:**
- Modify: `iot-learn-lab/infra/prometheus/scrape-device-report.yml`

> **网络关键：** Prometheus 在 Docker 桥接网络里时，默认可能 **够不着** `192.168.49.2`（minikube 节点网）。优先把容器连上 `minikube` 网络；备选 `network_mode: host`。

- [ ] **Step 1: 在 scrape 文件追加 K8s jobs**

在 `iot-learn-lab/infra/prometheus/scrape-device-report.yml` **末尾追加**（保留原有 IDEA / APISIX jobs）：

```yaml
# ----- Stage 2 W3：minikube NodePort（把 MINIKUBE_IP 换成 minikube ip 输出）-----
- job_name: device-report-service-k8s
  metrics_path: /actuator/prometheus
  static_configs:
    - targets:
        - 192.168.49.2:30765
      labels:
        env: learn-k8s
        service: device-report-service
        runtime: minikube
- job_name: command-dispatch-service-k8s
  metrics_path: /actuator/prometheus
  static_configs:
    - targets:
        - 192.168.49.2:30767
      labels:
        env: learn-k8s
        service: command-dispatch-service
        runtime: minikube
```

> 若你的 `minikube ip` 不是 `192.168.49.2`，**必须改成实际 IP**。IP 变了（删重建集群）要同步改 scrape 并 reload Prometheus。

- [ ] **Step 2: 把片段合并进运行中的 prometheus.yml**

按你 Phase 1 的习惯二选一：

**A. 若 prometheus 挂载了包含上述片段的配置目录：**

```bash
# 示例：配置在容器内 /etc/prometheus/prometheus.yml
docker exec prometheus-learn cat /etc/prometheus/prometheus.yml | tail -40
# 把 scrape-device-report.yml 里新增 job 追加进 scrape_configs 后：
docker exec prometheus-learn kill -HUP 1
# 或
curl -X POST http://127.0.0.1:9090/-/reload
```

**B. 若只是文档片段、需手动编辑宿主机文件：** 编辑实际被挂载的 `prometheus.yml`，追加同样两个 job，再 `docker restart prometheus-learn`。

- [ ] **Step 3: 让 Prometheus 容器够到 minikube 网段**

```bash
MINIKUBE_IP="$(minikube ip)"
# 把 prometheus 接到 minikube 创建的 docker 网络（名称一般就叫 minikube）
docker network connect minikube prometheus-learn || true

# 从 Prometheus 容器内探测 NodePort
docker exec prometheus-learn wget -qO- --timeout=5 \
  "http://${MINIKUBE_IP}:30765/actuator/prometheus" | head -c 200
echo
```

Expected: 能看到 Prometheus 文本指标（含 `# HELP` / `jvm_` / `http_server_requests` 等）

若 `docker network connect` 报已连接可忽略；若仍然超时，改用：

```bash
# 备选：确认从 WSL 宿主机可达后，用 host 网络跑 Prometheus（按你现有 compose 调整）
curl -sf "http://${MINIKUBE_IP}:30765/actuator/prometheus" | head -c 100
```

- [ ] **Step 4: 在 Prometheus UI 确认 target UP**

浏览器打开：`http://192.168.19.64:9090/targets`（或你的 Prometheus 地址）

Expected:

| Job | State |
|-----|-------|
| `device-report-service-k8s` | UP |
| `command-dispatch-service-k8s` | UP |

即时查询：

```promql
up{job="device-report-service-k8s"}
```

Expected: 值为 `1`

---

### Task 5: 扩展 `env.sh` + 场景脚本 K3

**Files:**
- Modify: `iot-learn-lab/scripts/stage2/env.sh`
- Create: `iot-learn-lab/scripts/stage2/scenario-k3-ingress-baseline.sh`

- [ ] **Step 1: 在 `env.sh` 追加变量**

在文件末尾、`echo` 块之前追加：

```bash
export INGRESS_HOST="${INGRESS_HOST:-device-report.iot-learn.local}"
export REPORT_NODE_PORT="${REPORT_NODE_PORT:-30765}"
export DISPATCH_NODE_PORT="${DISPATCH_NODE_PORT:-30767}"
# 动态取；minikube 未启动时允许为空
export MINIKUBE_IP="${MINIKUBE_IP:-$(minikube ip 2>/dev/null || true)}"
```

并在 echo 区追加：

```bash
echo "INGRESS_HOST=$INGRESS_HOST"
echo "MINIKUBE_IP=$MINIKUBE_IP"
echo "REPORT_NODE_PORT=$REPORT_NODE_PORT"
echo "DISPATCH_NODE_PORT=$DISPATCH_NODE_PORT"
```

- [ ] **Step 2: 创建 `scenario-k3-ingress-baseline.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "${SCRIPT_DIR}/env.sh"

NS="${K8S_NAMESPACE}"
HOST="${INGRESS_HOST}"
TS="$(date +%s)"
SAMPLES="${K3_LATENCY_SAMPLES:-20}"

echo "== K3: Ingress baseline + Prometheus NodePort =="

if [[ -z "${MINIKUBE_IP:-}" ]]; then
  echo "K3 FAIL: minikube ip 为空，请先 minikube start"
  exit 1
fi

kubectl rollout status deployment/device-report-service -n "$NS" --timeout=120s
kubectl get ingress,svc -n "$NS"

echo "-- Ingress via Host header (health) --"
curl -sf -H "Host: ${HOST}" "http://${MINIKUBE_IP}/actuator/health" | head -c 300
echo

echo "-- Ingress sync POST --"
DEVICE_INGRESS="k3-ingress-${TS}"
curl -sf -H "Host: ${HOST}" -X POST \
  "http://${MINIKUBE_IP}/api/v1/devices/${DEVICE_INGRESS}/reports" \
  -H "Content-Type: application/json" \
  -d "{\"payload\":{\"temp\":31,\"source\":\"k3-ingress\"}}"
echo

echo "-- NodePort metrics scrape (raw) --"
curl -sf "http://${MINIKUBE_IP}:${REPORT_NODE_PORT}/actuator/prometheus" | head -c 120
echo
curl -sf "http://${MINIKUBE_IP}:${DISPATCH_NODE_PORT}/actuator/prometheus" | head -c 120
echo

# 延迟对照：Ingress vs IDEA（若可达）vs NodePort
latency_avg() {
  local url="$1"
  local extra_curl_args=("${@:2}")
  local sum=0
  local i
  for ((i=1; i<=SAMPLES; i++)); do
    local t
    t="$(curl -s -o /dev/null -w '%{time_total}' "${extra_curl_args[@]}" "$url" || echo 9.999)"
    sum="$(awk -v a="$sum" -v b="$t" 'BEGIN{printf "%.6f", a+b}')"
  done
  awk -v s="$sum" -v n="$SAMPLES" 'BEGIN{printf "%.4f", s/n}'
}

HEALTH_PATH="/actuator/health"
INGRESS_URL="http://${MINIKUBE_IP}${HEALTH_PATH}"
NODEPORT_URL="http://${MINIKUBE_IP}:${REPORT_NODE_PORT}${HEALTH_PATH}"
IDEA_URL="http://${WSL_TO_WINDOWS_IP}:8765${HEALTH_PATH}"

echo "-- latency avg over ${SAMPLES} samples (health GET) --"
INGRESS_AVG="$(latency_avg "$INGRESS_URL" -H "Host: ${HOST}")"
NODEPORT_AVG="$(latency_avg "$NODEPORT_URL")"
echo "ingress_host_header_avg_s=${INGRESS_AVG}"
echo "nodeport_avg_s=${NODEPORT_AVG}"

if curl -sf --connect-timeout 1 "$IDEA_URL" >/dev/null 2>&1; then
  IDEA_AVG="$(latency_avg "$IDEA_URL")"
  echo "idea_direct_avg_s=${IDEA_AVG}"
else
  echo "idea_direct_avg_s=SKIP (Windows :8765 不可达；仅对照 Ingress vs NodePort)"
fi

echo
echo "K3 PASS: Ingress + NodePort metrics 路径打通"
```

- [ ] **Step 3: 赋权并运行**

```bash
chmod +x iot-learn-lab/scripts/stage2/scenario-k3-ingress-baseline.sh
iot-learn-lab/scripts/stage2/scenario-k3-ingress-baseline.sh
```

Expected: 输出 `K3 PASS`，并打印 `ingress_host_header_avg_s` / `nodeport_avg_s`

---

### Task 6: README + 面试笔记

**Files:**
- Modify: `iot-learn-lab/infra/k8s/README.md`
- Modify: `iot-learn-lab/docs/stage2-interview-notes.md`

- [ ] **Step 1: 在 README 追加「W3：Ingress + Prometheus」**

```markdown
## W3：Ingress + 外部 Prometheus

### 启用与部署

\`\`\`bash
minikube addons enable ingress
source scripts/stage2/env.sh
kubectl apply -f infra/k8s/device-report/service.yaml      # NodePort 30765
kubectl apply -f infra/k8s/command-dispatch/service.yaml  # NodePort 30767
kubectl apply -f infra/k8s/device-report/ingress.yaml
kubectl get ingress -n iot-learn
\`\`\`

### 访问

\`\`\`bash
# 推荐：Host 头（不改 /etc/hosts）
curl -H "Host: device-report.iot-learn.local" http://$(minikube ip)/actuator/health

# 可选：minikube tunnel + hosts
minikube tunnel
\`\`\`

### Prometheus

1. \`infra/prometheus/scrape-device-report.yml\` 增加 \`*-k8s\` jobs（target = \`$(minikube ip):30765/30767\`）
2. \`docker network connect minikube prometheus-learn\`
3. reload Prometheus → UI \`/targets\` 看 \`device-report-service-k8s\` UP

### 验证

\`\`\`bash
scripts/stage2/scenario-k3-ingress-baseline.sh
\`\`\`

### 口诀

| 概念 | 一句话 |
|------|--------|
| Service | 集群内稳定入口（DNS / ClusterIP / NodePort） |
| Ingress | 集群 **HTTP(S) L7** 入口（Host/Path → Service） |
| NodePort | 给 **集群外**（含 Docker 里的 Prometheus）开的固定端口 |
| ServiceMonitor | Operator 体系；本阶段用 static_configs 即可 |
\`\`\`
```

- [ ] **Step 2: 在 `stage2-interview-notes.md` 追加 W3**

在 W2 场景表后追加：

```markdown
## W3 场景记录

| 场景 | 日期 | 通过？ | 关键现象 |
|------|------|--------|----------|
| K3 Ingress + Prom | | ☐ | Host 头 health UP；NodePort scrape UP；K3 PASS；延迟数字已记录 |

## W3 面试题自测

1. Ingress 和 Service 分别解决什么问题？谁做 L4、谁做 L7？
2. 为什么 W3 用 NodePort 给 Prometheus，而不是继续 port-forward？
3. 从 Docker 里的 Prometheus 访问 `minikube ip` 失败时，你怎么排？
4. `ingressClassName: nginx` 和 minikube addon 是什么关系？
5. IDEA 直连通常比 Ingress 快还是慢？慢在哪几跳？

## 踩坑记录（W3）

| 踩坑 | 原因 | 处理 |
|------|------|------|
| | | |
```

---

## W3 完成标准（Checklist）

- [ ] `ingress-nginx-controller` Running；`device-report-ingress` 已创建
- [ ] `device-report-service` / `command-dispatch-service` 为 NodePort `30765` / `30767`
- [ ] Host 头访问 health UP，并能 POST `/api/v1/devices/{id}/reports`
- [ ] Prometheus jobs `device-report-service-k8s`、`command-dispatch-service-k8s` 为 **UP**
- [ ] `scenario-k3-ingress-baseline.sh` 输出 `K3 PASS`
- [ ] `infra/k8s/README.md` 含 W3 章节
- [ ] `stage2-interview-notes.md` W3 章节已填（含一次延迟数字）

---

## W3 面试话术速记

| 问题 | 答法 |
|------|------|
| Ingress 是什么？ | HTTP(S) 七层入口：按 Host/Path 转到后端 Service；不是替代 Service |
| 和 NodePort 区别？ | NodePort 是四层「节点 IP:端口→Service」；Ingress 是域名/路径路由，可挂 TLS |
| 外部 Prometheus？ | 混合架构下 Prometheus 仍在 Docker；用 NodePort + `minikube ip` static scrape；以后可上 ServiceMonitor |
| 延迟对照意义？ | 量化「多一跳代理」成本；为 W7 Rollouts / 网关对照打基线 |
| 为何暂不用 APISIX？ | Spec：W1–W3 先验证 Pod/Ingress；W4–W7 再把 APISIX upstream 指到 NodePort/Ingress |

---

## 常见踩坑

| 现象 | 原因 | 处理 |
|------|------|------|
| Ingress ADDRESS 一直空 | controller 未 Ready / 未 enable addon | `kubectl get pods -n ingress-nginx` |
| curl minikube IP 返回 404 | 没带 `Host` 头 | 加 `-H "Host: device-report.iot-learn.local"` |
| `ingressClassName` 不被承认 | 旧集群 / 类名不对 | `kubectl get ingressclass`；minikube 一般为 `nginx` |
| Prometheus target DOWN | 容器到不了 192.168.49.2 | `docker network connect minikube prometheus-learn` |
| scrape IP 变了全红 | minikube 重建 IP 变更 | 更新 prometheus.yml 后 reload |
| NodePort 被占 apply 失败 | 30765 冲突 | 换未占用端口并同步改 scrape / env.sh |
| tunnel 要密码 / 不稳定 | 权限与前台进程 | 学习场景用 Host 头即可 |

---

## 下一步（W4）

- 把 `infra/k8s/` 收成 Helm Chart：`infra/helm/iot-learn-lab/`
- `values.yaml` 外置镜像 tag、副本数、中间件 host
- 用 `helm upgrade --install` 代替裸 `kubectl apply`
- 脚本：`scenario-k4-helm-baseline.sh`；K2/K3 可继续复用

**W4 实施计划：** `docs/superpowers/plans/2026-07-17-stage2-w4-helm-chart.md`  
**W4 前置指南：** `docs/superpowers/guides/2026-07-17-stage2-w4-helm-primer.md`

---

## Spec 覆盖自检

| Spec 要求（Stage 2 W3 段） | 本计划 Task |
|---------------------------|-------------|
| `minikube addons enable ingress`；Ingress 规则 | Task 1、3 |
| Prometheus 增加 K8s Pod target（NodePort） | Task 2、4 |
| 压测对比 IDEA 直连 vs Ingress 延迟 | Task 5（K3 脚本） |
| `scenario-k3-ingress-baseline.sh` | Task 5 |

---

## 执行方式

**Plan complete and saved to `docs/superpowers/plans/2026-07-16-stage2-w3-ingress-prometheus.md`. Two execution options:**

1. **Subagent-Driven（推荐）** — 按 Task 派发子代理，每 Task 后 review  
2. **Inline Execution** — 本会话按 Task 1→6 连续执行，Checkpoint 在 Task 3 后（Ingress 通了再接 Prometheus）

**Which approach?**
