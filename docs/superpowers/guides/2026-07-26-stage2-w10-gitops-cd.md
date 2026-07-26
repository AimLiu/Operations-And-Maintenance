# Stage2 W10 · GitOps CD（GHCR → 集群）指南

> **配套计划**：[`../plans/2026-07-26-stage2-w10-gitops-cd.md`](../plans/2026-07-26-stage2-w10-gitops-cd.md)  
> **Spec**：[`../../../.cursor/plans/iot_learn_lab_stage2_spec.md`](../../../.cursor/plans/iot_learn_lab_stage2_spec.md) · **Block E · W10**  
> **前置**：W9 Actions 已推 GHCR（有 `sha-<40位>` 镜像）；W4 Argo Application 可 Sync；W3 混合网络正常

---

## 0. 为什么需要 W10

W9 只解决「推到 GHCR」。本仓库 Helm 默认仍是本地标签：

```yaml
image: device-report-service:0.1.0-SNAPSHOT
```

Argo Sync 后 kubelet 在节点上找不到该镜像 → 仍依赖手工 `minikube image load`。

**W10 目标**：把 `values.yaml`（及覆盖层）里的 `image` 改成 GHCR 完整引用 → Sync → Pod 从 GHCR 拉取 → **结束「改代码 → load → restart」循环**。

```text
git push → Actions → GHCR:sha-xxx
                ↓
改 values image → commit → Argo Sync
                ↓
Pod 拉 GHCR → Ready（无需 minikube image load）
```

---

## 1. 与 W9 的边界

| | W9 | W10 |
|--|----|-----|
| 产物 | GHCR 镜像 + Packages | 集群跑 GHCR 镜像 |
| 改 Helm？ | 否 | **是** |
| 需要 Argo？ | 否 | **是** |
| 结束手工 load？ | 否 | **是（本周目标）** |

W10 **不**要求：每次 push 自动改 values（可用手工改 SHA）；不要求生产级 SealedSecrets。

---

## 2. image 字段约定（本仓库）

模板是：

```yaml
image: {{ .Values.deviceReport.image | quote }}
```

因此 `values` 里应是**完整字符串**，不是 `repository`/`tag` 对象：

```yaml
# ✅
image: ghcr.io/aimliu/device-report-service:sha-acdf94545e4e751126b3c5596cb25dbe1fd0f202

# ❌ 会破坏现有模板
image:
  repository: ghcr.io/aimliu/device-report-service
  tag: sha-...
```

覆盖层（`values-v1.yaml` / `values-v2.yaml` / `values-minikube.yaml`）若未写 `image`，则继承 `values.yaml`。

---

## 3. 公有 vs 私有 GHCR

| Packages 可见性 | 集群侧 |
|-----------------|--------|
| **Public** | 一般无需 `imagePullSecrets` |
| **Private** | 需 `docker-registry` Secret + Deployment/Rollout `imagePullSecrets` |

本学习环境优先 **Public**，少踩权限坑。若必须 Private：用 PAT（`read:packages`）建 Secret，**勿把 PAT 提交进 Git**。

---

## 4. 推荐操作节奏

1. 在 GitHub Packages / Actions 摘要确认三个 `sha-<commit>` 镜像存在  
2. 改 `values.yaml` 三个 `image` 为完整 GHCR URL  
3. `helm template` 确认输出含 `ghcr.io/...`  
4. commit + push → Argo Sync（或 UI Sync）  
5. `kubectl describe pod` 看 `Successfully pulled image "ghcr.io/..."`  
6. 业务冒烟（report → dispatch → consumer）  
7. （可选）再改一次 SHA，证明「只改 values + Sync」即可升级，无需 load  

---

## 5. 常见失败

| 现象 | 原因 | 处理 |
|------|------|------|
| `ErrImagePull` / `401` | 私有包无 Secret | Public 或加 pull secret |
| `ImagePullBackOff` 一直转 | tag 写错 / 镜像未推上 | 核对 Packages 与 SHA |
| Sync 了仍是旧镜像 | values 未提交或 Application 未指到该 commit | 查 Argo revision / Hard Refresh |
| 拉很慢 | 国内拉 GHCR | 等；或临时 mirror（进阶） |
| Feign/业务挂 | 与拉镜像无关 | 查 ConfigMap / middleware IP |

---

## 6. 与「本地 SNAPSHOT」并存

本地调试仍可用 `minikube image load` + 改回 `*:0.1.0-SNAPSHOT`。  
**推荐默认走 GHCR**；仅排障时切回本地。

---

## 7. 验收一句话

> 改 `values` 里的 GHCR `sha-*` → Git → Argo Sync → Pod Ready 且日志可见 `Successfully pulled image "ghcr.io/..."` → 业务通 → **全程无 `minikube image load`**。
