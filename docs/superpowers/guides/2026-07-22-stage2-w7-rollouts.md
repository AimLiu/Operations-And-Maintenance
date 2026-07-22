# Stage 2 W7 前置知识：Argo Rollouts 金丝雀

**读者：** 已完成 W6（Argo CD Application 管 Helm Chart，Synced/Healthy），理解 W5 values-v2 + canary-bug，做过或读过 Phase 4 APISIX 90/10 金丝雀  
**范围：** Stage 2 W7（安装 Rollouts、Deployment→Rollout、canary steps、abort/promote、可选 Analysis）  
**对照计划：** `docs/superpowers/plans/2026-07-22-stage2-w7-rollouts.md`  
**不讲：** Jaeger（W8）；GitHub Actions（W9–W10）；Service Mesh 流量插件细节

读完你应能回答八件事：

1. Argo CD 和 Argo Rollouts 分别管什么  
2. 为什么金丝雀要用 `Rollout` 而不是改 Ingress 权重  
3. canary `setWeight` 在无 Istio 时大致怎么生效  
4. stable / canary ReplicaSet 与一次「改 Pod 模板」的关系  
5. `abort` / `promote` / `pause` 各干什么  
6. 为什么必须看 `version=v2` 错误率，而不是集群总 5xx  
7. abort 之后为什么还要改 Git（GitOps）  
8. Phase 4 APISIX 金丝雀与 W7 Rollouts 怎么对照着讲  

---

## 1. 先看一串你马上要敲的命令

```bash
# 安装 Rollouts
kubectl create namespace argo-rollouts
kubectl apply -n argo-rollouts -f \
  https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml

# 插件（推荐）
kubectl argo rollouts version

# 观察（Rollout 就绪后）
kubectl argo rollouts get rollout device-report-service -n iot-learn --watch

# 放行暂停步骤 / 中止回滚
kubectl argo rollouts promote device-report-service -n iot-learn
kubectl argo rollouts abort device-report-service -n iot-learn

# 场景脚本
iot-learn-lab/scripts/stage2/scenario-k7-rollouts-canary.sh
```

成功结业时大致是：触发 v2+bug 金丝雀 → 看到部分 5xx → abort → 恢复 → `K7 PASS`。

---

## 2. 和 W5 / W6 / Phase 4 对比

| 以前 | W7 |
|------|-----|
| W5：`values-v2` **整池**切到 v2 | Rollout：**一部分**流量/副本先试 v2 |
| W6：Sync 后对象立刻接近期望 | Sync 后进入 **渐进 steps**（10→50→100） |
| Phase 4：APISIX upstream 权重 | 集群内 **发布控制器** 调 ReplicaSet |
| 回滚脚本改网关 | `rollouts abort` 回 **上一稳定 ReplicaSet** |

口诀：

> **W6 保证「集群跟上 Git」；W7 保证「跟上 Git 时别一次切全量」。**

---

## 3. Argo CD ≠ Argo Rollouts

```text
Argo CD
  · 读 Git / 渲染 Helm
  · 把 Rollout、Service、ConfigMap 等「声明」同步进集群
  · Synced / Self-heal / Prune

Argo Rollouts
  · 盯着 kind: Rollout
  · 当 Pod 模板变化时，按 canary/blueGreen 策略推进
  · 创建 AnalysisRun、执行 abort/promote
```

两者常一起用，但是 **两个控制器**：

| 问题 | 找谁 |
|------|------|
| Git 改了 values，集群没变 | Argo CD Sync |
| Sync 了，新版本卡在 10% pause | Rollouts（promote / 等 duration） |
| 金丝雀出错要立刻回旧版 | `rollouts abort` |
| abort 后下次 Sync 又发 v2 | Git 仍是 v2 → 改回 Git |

---

## 4. Deployment vs Rollout

| | Deployment | Rollout |
|--|------------|---------|
| API | `apps/v1` | `argoproj.io/v1alpha1` |
| 升级默认 | RollingUpdate（逐步换，但 **不是** 按业务错误率停） | canary / blueGreen **可暂停、可分析、可 abort** |
| 流量语义 | 新旧 Pod 共用 Service，比例≈就绪副本比 | canary `setWeight` +（可选）流量插件 |

W7 只把 **device-report** 换成 Rollout；dispatch / consumer 继续 Deployment，降低心智负担。

Helm 里用开关互斥，避免同名 Deployment + Rollout 抢同一组 Pod 标签：

```text
rollouts.enabled=false → 渲染 Deployment（W4–W6 老路）
rollouts.enabled=true  → 渲染 Rollout（W7）
```

---

## 5. 一次金丝雀在集群里长什么样

```text
改 Git：versionLabel=v2, canaryBugEnabled=true
        │
        ▼
Argo CD 更新 Rollout.spec.template
        │
        ▼
Rollouts：保留旧 RS = stable（v1）
         新建 RS = canary（v2）
         steps: setWeight 10 → pause → 50 → pause → 100
        │
        ├─ 成功 → canary 变新的 stable
        └─ abort → 缩掉 canary，流量回旧 stable
```

**无 Service Mesh 时：** `setWeight` 通常靠调整 stable/canary 副本比例近似权重。  
因此学习环境建议 `replicaCount >= 2`，否则「10%」很难有体感。

---

## 6. pause / promote / abort

| 动作 | 含义 |
|------|------|
| `pause`（step） | 停住，等人或等 Analysis，或等 `duration` |
| `promote` | 跳过当前 pause，继续下一步（或全放行，视参数） |
| `abort` | **失败回滚**：回到升级前的 stable 版本 |

注意：`abort` 是 **发布进度** 回滚，不是 Git revert。  
GitOps 下若期望状态仍是 v2，控制器/下次 Sync 还可能再开一轮 —— **结业必须把 Git 改回健康期望**。

---

## 7. 为什么必须看 `version=v2`

Phase 4 / Stage 2 同一条面试点：

```text
稳定版 90% 流量几乎全成功
金丝雀 10% 全是 5xx
────────────────────────
「总错误率」≈ 9%   ← 容易被当成「还行」
version=v2 错误率 ≈ 100%  ← 才该 abort
```

AnalysisTemplate（加分项）应对 **带 version 标签** 的 Prometheus 查询设阈值（例如 >5%），而不是裸看全局 5xx。

本 lab Prometheus 在 Docker：Analysis 的 address 常用 `http://host.minikube.internal:9090`。先保证 Pod 能访问 Prom，再开自动分析。

---

## 8. Phase 4 APISIX vs W7 Rollouts（面试表）

| 维度 | Phase 4（APISIX） | Stage 2 W7（Rollouts） |
|------|-------------------|-------------------------|
| 切流位置 | 网关 upstream 权重 | 工作负载 canary weight |
| 谁执行 | APISIX 配置 / 脚本 | Rollouts Controller |
| 观测 | Grafana `version` | 同左 + 可选 AnalysisRun |
| 回滚 | `bootstrap-canary-rollback.sh` | `kubectl argo rollouts abort` |
| 和 GitOps | 往往另改网关配置 | 期望状态在 Git；发布策略在 Rollout |

一句话：

> 「入口金丝雀管 **流量调度**；Rollouts 管 **应用版本放量**。生产里两者可以叠，但 lab 分阶段对照学。」

---

## 9. 和 Argo CD Self-heal 的摩擦（提前知道）

金丝雀过程中 Rollout 的 replicas / status 会变。若 Application 开了 **automated + selfHeal**，可能出现：

- 你刚 abort，Sync 又把模板差异打回来  
- Diff 一直吵 status 字段  

处理原则（学习环境）：

1. 做 K7 演练时可暂时关掉 automated，或  
2. 对 Rollout 配合理的 `ignoreDifferences`，或  
3. 接受「先 abort，立刻把 Git 改回 v1 并 Sync」的纪律  

以 **能完成 abort 故事** 为准，不要在 ignore 规则上钻太深。

---

## 10. W7 故意还没碰的东西

| 主题 | 放到 |
|------|------|
| Jaeger / OTel 全链路 | W8 |
| CI 改 `image.tag` 触发 Rollout | W9–W10 |
| Istio/NGINX 精细流量插件 | 选修 |
| 蓝绿 blueGreen 主路径 | 选修口述即可 |

---

## 11. 建议阅读顺序

1. 本文  
2. 计划 `docs/superpowers/plans/2026-07-22-stage2-w7-rollouts.md` Task 1→4  
3. 官方：[Argo Rollouts Getting Started](https://argo-rollouts.readthedocs.io/en/stable/getting-started/)  
4. 对照：`iot-learn-lab/docs/phase4-interview-notes.md` 金丝雀章节  

读完直接按计划 Task 1 安装 Controller 即可。
