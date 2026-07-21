# Stage 2 Helm 速查

**Chart 路径：** `infra/helm/iot-learn-lab/`  
**Release 名：** `iot-learn` · **Namespace：** `iot-learn`  
**前置指南：** `docs/superpowers/guides/2026-07-17-stage2-w4-helm-primer.md`、`…/2026-07-19-stage2-w5-helm-values.md`  
**命令默认在 `iot-learn-lab/` 目录下执行。**

---

## 标准安装（三层 values）

```bash
helm upgrade --install iot-learn infra/helm/iot-learn-lab -n iot-learn \
  -f infra/helm/iot-learn-lab/values.yaml \
  -f infra/helm/iot-learn-lab/values-minikube.yaml \
  -f infra/helm/iot-learn-lab/values-v1.yaml \
  --wait --timeout 5m
```

---

## 切 v2 + canary-bug / 切回

```bash
# v2（versionLabel=v2 + APP_CANARY_BUG_ENABLED=true）
helm upgrade iot-learn infra/helm/iot-learn-lab -n iot-learn \
  -f infra/helm/iot-learn-lab/values.yaml \
  -f infra/helm/iot-learn-lab/values-minikube.yaml \
  -f infra/helm/iot-learn-lab/values-v2.yaml \
  --wait --timeout 5m

# 切回 v1
helm upgrade iot-learn infra/helm/iot-learn-lab -n iot-learn \
  -f infra/helm/iot-learn-lab/values.yaml \
  -f infra/helm/iot-learn-lab/values-minikube.yaml \
  -f infra/helm/iot-learn-lab/values-v1.yaml \
  --wait --timeout 5m
```

快速自检：

```bash
kubectl get pods -n iot-learn -l app=device-report-service --show-labels
kubectl get cm device-report-middleware -n iot-learn -o yaml | grep -E 'APP_'
```

---

## 常用命令

| 命令 | 用途 |
|------|------|
| `helm lint infra/helm/iot-learn-lab` | 安装前静态检查 Chart |
| `helm template iot-learn infra/helm/iot-learn-lab -n iot-learn -f ... \| less` | 只渲染、不写集群 |
| `helm upgrade --install ... --wait` | 安装或升级 |
| `helm status iot-learn -n iot-learn` | Release 状态 |
| `helm history iot-learn -n iot-learn` | revision 历史 |
| `helm rollback iot-learn N -n iot-learn` | 回滚到 revision N |
| `helm get values iot-learn -n iot-learn` | 看合并后的 values |
| `helm uninstall iot-learn -n iot-learn` | 删除 Release（慎用） |

---

## Values 分层口诀

| 顺序 | 文件 | 层 |
|------|------|----|
| 1 | `values.yaml` | 结构与默认（端口、Ingress、资源…） |
| 2 | `values-minikube.yaml` | **环境**（DB/Redis/Kafka/Nacos…） |
| 3 | `values-v1.yaml` / `values-v2.yaml` | **版本**（label / canary / APP_*） |

后写的 `-f` 覆盖先写的。临时实验可用 `--set key=value`（别忘了事后写回文件）。

---

## `versionLabel` vs `appVersion`

| values 字段 | 落点 | 怎么看 |
|-------------|------|--------|
| `versionLabel` | Pod label `version=` | `kubectl get pods --show-labels` |
| `appVersion` | ConfigMap `APP_VERSION` → Spring `app.version` → Prometheus `version` 标签 | `kubectl get cm ... \| grep APP_VERSION` |
| `canaryBugEnabled` | ConfigMap `APP_CANARY_BUG_ENABLED` | 同上；为 true 时上报易 5xx |

`Chart.yaml` 里的 `appVersion` 只是 Chart 元数据，不会自动进 Pod/应用。

---

## ConfigMap 与 checksum

- 改 middleware / `APP_*` → ConfigMap 变 → Pod 模板上 `checksum/config` 变 → **自动滚 Pod**
- 没有 checksum 时：etcd 里 ConfigMap 已新，旧容器 env 仍旧 → 需 `kubectl rollout restart`
- **相同 values 反复 upgrade 不会滚**（哈希不变）；验证 checksum 时必须改一个真实会出现在对应 ConfigMap 里的字段

```bash
# 示例：故意改 nacosAddr 触发 report 滚动，再改回
OLD_POD=$(kubectl get pod -n iot-learn -l app=device-report-service -o jsonpath='{.items[0].metadata.name}')
helm upgrade iot-learn infra/helm/iot-learn-lab -n iot-learn \
  -f infra/helm/iot-learn-lab/values.yaml \
  -f infra/helm/iot-learn-lab/values-minikube.yaml \
  -f infra/helm/iot-learn-lab/values-v1.yaml \
  --set middleware.nacosAddr=192.168.19.64:8849 \
  --wait
NEW_POD=$(kubectl get pod -n iot-learn -l app=device-report-service -o jsonpath='{.items[0].metadata.name}')
test "$OLD_POD" != "$NEW_POD" && echo CHECKSUM_ROLL_OK || echo CHECKSUM_ROLL_FAIL
# 记得再 upgrade 把 nacosAddr 改回 8848
```

---

## Ingress / NodePort（Helm 渲出，用法同 W3）

```bash
source scripts/stage2/env.sh
curl -sf -H "Host: ${INGRESS_HOST}" "http://${MINIKUBE_IP}/actuator/health"
curl -sf "http://${MINIKUBE_IP}:${REPORT_NODE_PORT}/actuator/prometheus" | head
```

Prometheus 在 Docker 里 scrape NodePort 时，若 target DOWN：

```bash
docker network connect minikube prometheus-learn
```

---

## Helm vs Kustomize（面试一句）

| | Helm | Kustomize |
|--|------|-----------|
| 模型 | 模板 + values 包管理 | 无模板，base + overlay 补丁 |
| 生命周期 | Release / rollback 一等公民 | 偏 `kubectl apply -k` |
| 本仓库 | Stage 2 主线 | 了解即可，不迁移 |

---

## 场景脚本

| 脚本 | 验证 |
|------|------|
| `scripts/stage2/scenario-k4-helm-baseline.sh` | Helm Release + Ingress/NodePort 冒烟 |
| `scripts/stage2/scenario-k5-helm-values-switch.sh` | v1 → v2+canary(5xx) → 切回 v1 |

```bash
./scripts/stage2/scenario-k4-helm-baseline.sh
./scripts/stage2/scenario-k5-helm-values-switch.sh
```

---

## 同 tag 换镜像（改了 `application-k8s.yml` 之后）

```bash
mvn -B -pl device-report-service -am package -DskipTests
docker build -f device-report-service/Dockerfile -t device-report-service:0.1.0-SNAPSHOT .
kubectl scale deploy/device-report-service -n iot-learn --replicas=0   # 若 image rm 报占用
minikube image rm device-report-service:0.1.0-SNAPSHOT || true
minikube image load device-report-service:0.1.0-SNAPSHOT
helm upgrade iot-learn infra/helm/iot-learn-lab -n iot-learn \
  -f infra/helm/iot-learn-lab/values.yaml \
  -f infra/helm/iot-learn-lab/values-minikube.yaml \
  -f infra/helm/iot-learn-lab/values-v1.yaml \
  --wait
```
