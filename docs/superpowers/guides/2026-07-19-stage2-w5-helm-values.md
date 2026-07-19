# Stage 2 W5 前置知识：Values 分层、ConfigMap checksum 与 canary 切换

**读者：** 已完成 W4（Helm Chart 可 install/upgrade/rollback），知道 Chart/Release/Values，但还没做过「多文件 values 分层」和「改配置自动滚 Pod」  
**范围：** Stage 2 W5（环境 values、checksum、一条命令切 v2+canary-bug、Helm vs Kustomize）  
**对照计划：** `docs/superpowers/plans/2026-07-19-stage2-w5-helm-values.md`  
**不讲：** Argo CD、Rollouts 流量分割、双 Deployment 并行金丝雀（W6–W7）

读完你应能回答七件事：

1. 为什么要把 values 拆成「结构 / 环境 / 版本」三层  
2. `values-minikube.yaml` 解决什么问题  
3. ConfigMap 改了为什么旧 Pod 还用旧环境变量  
4. checksum 注解如何让 `helm upgrade` 自动滚 Pod  
5. 一条命令切 v2+canary-bug 时，到底改了集群里的什么  
6. 为什么 W5 不用 Nacos 热更新 canary  
7. Helm 和 Kustomize 各适合什么（面试一句）  

---

## 1. 先看一串你马上要敲的命令

```bash
# 标准三层（W5 起推荐固定顺序）
helm upgrade --install iot-learn iot-learn-lab/infra/helm/iot-learn-lab -n iot-learn \
  -f iot-learn-lab/infra/helm/iot-learn-lab/values.yaml \
  -f iot-learn-lab/infra/helm/iot-learn-lab/values-minikube.yaml \
  -f iot-learn-lab/infra/helm/iot-learn-lab/values-v1.yaml \
  --wait

# 一条命令切到 v2 + canary-bug
helm upgrade iot-learn iot-learn-lab/infra/helm/iot-learn-lab -n iot-learn \
  -f .../values.yaml -f .../values-minikube.yaml -f .../values-v2.yaml --wait

# 场景脚本
iot-learn-lab/scripts/stage2/scenario-k5-helm-values-switch.sh
```

成功时大致会看到：

```text
... http=500
...
K5 PASS: v2+canary produced 5xx; v1 restored
```

下面解释：**为什么加一层 values、为什么加 checksum、切换时集群里发生了什么。**

---

## 2. 和 W4 / Phase 4 对比

| 以前 | W5 |
|------|-----|
| W4：`values-v2` 只改 `versionLabel` | 真正打开 `canary-bug` + `APP_VERSION` |
| 改 ConfigMap 后常要手敲 `rollout restart` | checksum → upgrade 自动滚 |
| Phase 4：Nacos / 双端口 v1+v2 | 集群内 **同一 Deployment** 用 values 切换「行为版本」 |
| 中间件地址只写在 `values.yaml` | 抽到 `values-minikube.yaml`（环境层） |

W5 **不是** APISIX 10% 金丝雀；那是 W7 Rollouts 的故事。W5 练的是：**用 Helm values 管理可变配置与版本开关。**

---

## 3. Values 三层：结构 / 环境 / 版本

```text
values.yaml              ← 结构默认（服务名、端口、资源、Ingress 骨架）
values-minikube.yaml     ← 环境（DB/Redis/Kafka/Nacos 地址）
values-v1.yaml / v2.yaml ← 版本（version label、canary 开关、镜像 tag）
```

| 层 | 文件 | 谁改、何时改 |
|----|------|----------------|
| 结构 | `values.yaml` | 服务端口、副本默认、Ingress 是否启用 |
| 环境 | `values-minikube.yaml` | 换机器/换 IP 时只改这里 |
| 版本 | `values-v1` / `values-v2` | 发布演练、开 bug、打 version 标签 |

口诀：

> **-f 顺序：结构 → 环境 → 版本；后写的覆盖先写的。**

以后若有 CI 集群，可新增 `values-ci.yaml` 替换「环境层」，结构与版本层复用。

---

## 4. `values.yaml` 仍不是 Spring 配置

和 W4 相同，再强调一次：

| 文件 | 角色 |
|------|------|
| Helm `values*.yaml` | 部署参数 → 渲染 ConfigMap/Deployment |
| ConfigMap 环境变量 | 容器启动时注入 |
| `application-k8s.yml` | 声明「从哪个环境变量读到 `app.*`」 |

W5 在 ConfigMap 增加：

```text
APP_VERSION=v2
APP_CANARY_BUG_ENABLED=true
```

对应应用：

```yaml
app:
  version: ${APP_VERSION:v1}
  canary-bug-enabled: ${APP_CANARY_BUG_ENABLED:false}
```

这与 Phase 4 的 `app.canary-bug-enabled` **同一开关**，只是配置来源从 Nacos 换成 Helm→ConfigMap。

---

## 5. ConfigMap「更新了」≠ 进程「用上了」

```text
helm upgrade
  → etcd 里 ConfigMap 已是新值
  → 正在跑的容器环境变量仍是旧快照
  → 业务行为不变（直到新 Pod）
```

W2/W4 的解法是手工：

```bash
kubectl rollout restart deployment/device-report-service -n iot-learn
```

W5 用 **checksum** 把「重启」嵌进 upgrade。

---

## 6. checksum 注解在干什么？

在 **Pod 模板**（不是 Deployment 外壳）上写：

```yaml
spec:
  template:
    metadata:
      annotations:
        checksum/config: <ConfigMap 模板内容的 sha256>
```

```text
ConfigMap 内容变化
        → checksum 字符串变化
        → Pod template 与旧 ReplicaSet 不同
        → Deployment 滚动创建新 Pod
```

注意：

- 注解必须在 `spec.template.metadata.annotations`  
- 打在 `Deployment.metadata` 上 **不会**触发滚更  

面试一句：

> 「用配置内容的哈希当 Pod 模板的一部分，配置变更即滚动更新，缓解 envFrom 不热更新的问题。」

---

## 7. 「一条命令切 v2」时集群里变了什么？

```bash
helm upgrade ... -f values-v2.yaml
```

通常同时发生：

| 变化 | 来源 |
|------|------|
| Pod label `version=v2` | `versionLabel` |
| ConfigMap `APP_VERSION=v2` | `appVersion` |
| ConfigMap `APP_CANARY_BUG_ENABLED=true` | `canaryBugEnabled` |
| checksum 变 → Pod 重建 | Task 4 注解 |
| 上报开始 5xx | `CanaryBugConfig.maybeFail()` |

切回 `values-v1.yaml` 则反向恢复。

这与「两个 Deployment 各跑 v1/v2 + 网关拆流量」不同：W5 是 **同一工作负载切换配置/标签**，为 W7 金丝雀打基础认知。

---

## 8. 为什么 W5 不用 Nacos 热更新 canary？

| Phase 4（IDEA） | Stage 2 k8s profile |
|-----------------|---------------------|
| Nacos 配 `app.canary-bug-enabled` + `@RefreshScope` | discovery/config **关闭**（混合部署踩坑） |
| 适合本机热更演示 | 用 ConfigMap + 滚更更稳、更好讲「不可变配置」 |

面试可说：

> 「集群阶段把开关外置到 Helm values；需要热更且无抖动时再考虑 Nacos/配置中心，那是另一条对照实验。」

---

## 9. Helm vs Kustomize（面试向）

| 维度 | Helm | Kustomize |
|------|------|-----------|
| 核心模型 | 模板 + values | 无模板：base + overlay patch |
| 包/生命周期 | Chart、Release、rollback | 主要是渲染后 `kubectl apply -k` |
| 参数化 | `.Values` 很强 | 靠 patch / replacements |
| 学习曲线 | 要懂一点模板语法 | YAML 补丁心智简单 |
| 本仓库选择 | **Stage 2 主线** | 了解对比即可 |

两者都能「多环境」；你们已有 Chart + Release 历史，W5 继续加深 values，而不是换工具。

口诀：

> **Helm 像带版本的安装包；Kustomize 像同一份底稿贴不同补丁。**

---

## 10. K5 相对 K4 多验证了什么？

| 脚本 | 重心 |
|------|------|
| K4 | Release 能装、history/rollback 意识 |
| **K5** | **三层 values**、**checksum 自动滚**、**v2+canary 切换** |

K2/K3 在 v1 稳定态仍应可 PASS；K5 中途会故意制造 5xx，属预期。

---

## 11. 排障顺序

```text
1. helm get values iot-learn -n iot-learn
   → 合并结果里 canary / middleware 对不对？
2. kubectl get cm device-report-middleware -o yaml
   → APP_* 在不在？
3. kubectl exec ... -- env | grep APP_
   → 进程环境变量是否已是新值？
4. 若 CM 新、env 旧 → checksum 是否打在 pod template？
5. 应用日志有无 Canary bug config loaded: ...=true？
6. 镜像是否 rebuild？（改了 application-k8s.yml 必须 load）
```

---

## 12. 命令速查

```bash
helm upgrade --install iot-learn infra/helm/iot-learn-lab -n iot-learn \
  -f values.yaml -f values-minikube.yaml -f values-v1.yaml --wait

helm upgrade iot-learn infra/helm/iot-learn-lab -n iot-learn \
  -f values.yaml -f values-minikube.yaml -f values-v2.yaml --wait

kubectl get pods -n iot-learn -l app=device-report-service --show-labels
kubectl describe pod -n iot-learn -l app=device-report-service | grep -A2 checksum

iot-learn-lab/scripts/stage2/scenario-k5-helm-values-switch.sh
```

速查长文：`iot-learn-lab/docs/stage2-helm-cheatsheet.md`（W5 Task 7 产出）

---

## 13. W5 故意还没碰的东西

| 概念 | 何时 |
|------|------|
| Argo CD GitOps Sync | W6 |
| 双版本流量 10%→50%→100% | W7 Rollouts |
| AnalysisTemplate 看 version=v2 错误率 | W7 |
| 真·独立 v2 镜像仓库 tag | W9 CI/GHCR |

---

## 14. 自测题（合上文档回答）

1. 三层 `-f` 的推荐顺序是什么？谁覆盖谁？  
2. 只改 ConfigMap、没有 checksum、也不 restart，应用会用新 DB_HOST 吗？  
3. checksum 注解必须写在 Deployment 的哪一段 metadata 下？  
4. `values-v2.yaml` 打开 canary 后，Prometheus 的 `version` 标签从哪来？  
5. Helm 和 Kustomize 各用一句话概括。  
6. W5 的「切 v2」和 Phase 4「APISIX 金丝雀」差在哪里？

答不上来就回到对应小节；能答上来再执行 `2026-07-19-stage2-w5-helm-values.md`。
