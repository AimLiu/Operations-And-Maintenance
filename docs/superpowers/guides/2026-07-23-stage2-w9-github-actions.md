# Stage 2 W9 前置知识：GitHub Actions 与 GHCR

**读者：** 已完成 W8（Jaeger + OTLP；Feign 同 TraceId；Kafka producer 可见），能用 Argo CD Sync Chart，但仍靠本机 `docker build` + `minikube image load` 换镜像  
**范围：** Stage 2 W9——用 **GitHub Actions** 跑测试、构建三服务镜像并推到 **GHCR**  
**对照计划：** `docs/superpowers/plans/2026-07-23-stage2-w9-github-actions.md`  
**不讲：** 自动改 Helm `image` tag、Argo 自动拉新镜像部署（**W10**）；综合金丝雀+CI 终极演练（Block F）

读完你应能回答八件事：

1. CI 和 CD / GitOps 各负责哪一段  
2. 为什么学习环境要从「本机 load」过渡到「CI 推仓库」  
3. GHCR 镜像名、tag（短 SHA）怎么定  
4. `GITHUB_TOKEN` 需要哪些 `permissions`  
5. 工作流为何要限定 `iot-learn-lab/**` 路径（或 `workflow_dispatch`）  
6. 多阶段 Dockerfile 在 CI 里和 W1 本地 build 有何同异  
7. 私有 Package 时 minikube / Argo 怎样拉镜像（概念即可，落地多在 W10）  
8. W9 完成标准是什么（Actions 绿 + GHCR 有三镜像），什么故意留给 W10  

---

## 1. 先看一串你马上会碰到的概念

```text
git push（改了 Java / Dockerfile）
        │
        ▼
GitHub Actions: iot-learn-lab-ci.yml
        │  mvn verify（或 -DskipTests 的折中，计划里定）
        │  docker build × 3
        │  docker push ghcr.io/<owner>/<svc>:<short-sha>
        ▼
GHCR 上出现三张镜像
        │
        ✗  W9 停在这里（人还可用 crane/docker pull 自测）
        │
        ▼  W10 才做
改 values.yaml image → commit → Argo Sync → 集群滚动
```

成功时 Actions 摘要大致是：

```text
✓ test
✓ build-and-push (device-report-service)
✓ build-and-push (command-dispatch-service)
✓ build-and-push (device-report-consumer)
```

---

## 2. 和 W1 / W6 / W8 对比

| 以前 | W9 |
|------|-----|
| 本机 `docker build` + `minikube image load` | **CI 构建** + **推 GHCR** |
| tag 固定 `0.1.0-SNAPSHOT` | tag 用 **git short SHA**（可追溯、可回滚叙述） |
| 真相源 = 你笔记本上的镜像层 | 真相源 = **仓库里的 commit + 对应镜像** |
| W6 Argo 已管 Chart | W9 **还不自动改** Chart 里的 image |
| W8 可观测已通 | W9 不改 tracing；部署后仍用 Jaeger/Prom 验（W10） |

口诀：

> **W9 把「构建产物」搬进制品库；W10 才把「制品版本」写进 Git 让 Argo 跟上。**

---

## 3. CI ≠ CD（面试高频）

用 **Continuous Delivery**（Humble / Farley）的拆法：

| 阶段 | 问题 | W9 | W10 |
|------|------|----|-----|
| **CI** | 每次提交能否证明「可构建、可测试、有制品」？ | ✅ Actions + GHCR | — |
| **CD / GitOps** | 制品如何变成集群期望状态？ | ❌ 不做 | ✅ 改 values + Argo |

再叠一层 **Accelerate** 的反馈环：缩短「提交 → 可部署制品」的反馈；集群是否立刻变，是下一环。

---

## 4. GHCR 是什么？

**GitHub Container Registry**（`ghcr.io`）：和代码同账号/组织的容器仓库。

典型镜像引用：

```text
ghcr.io/aimliu/device-report-service:a1b2c3d
         │       │                    │
         │       │                    └─ tag = 短 commit SHA（计划约定）
         │       └─ 镜像名（可与服务名一致）
         └─ 小写 owner（GHCR 要求小写）
```

注意：GitHub 用户名若为 `AimLiu`，GHCR 路径多为 **`ghcr.io/aimliu/...`**（小写）。

相对 Docker Hub：无需另开账号；`GITHUB_TOKEN` 在 Actions 里即可推（配好 `packages: write`）。

---

## 5. Workflow 心智模型

```yaml
# 概念结构（完整见计划 Task）
name: iot-learn-lab-ci
on:
  push:
    paths: ['iot-learn-lab/**', '.github/workflows/iot-learn-lab-ci.yml']
  workflow_dispatch: {}   # 手动跑

permissions:
  contents: read
  packages: write

jobs:
  test:           # JDK 21 + mvn -pl ... verify
  build-and-push: # matrix: 三个 Dockerfile → GHCR
```

| 旋钮 | 建议（lab） |
|------|-------------|
| 触发 | `iot-learn-lab/**` 变更，避免无关 md 刷流水线 |
| 权限 | 最小：`contents: read` + `packages: write` |
| 缓存 | 可选 `actions/cache` / Buildx cache；首版可不做 |
| 失败策略 | test 失败则不 push（`needs: test`） |

---

## 6. 镜像 tag 策略（W9 定调，W10 沿用）

| 策略 | 本 lab |
|------|--------|
| `:latest` | **不用**（不可追溯） |
| `:0.1.0-SNAPSHOT` | 仅本地/旧习惯；CI **改推 SHA** |
| `:<git-sha-7>` | **W9 主 tag** |
| 额外 `:main` / semver | W10+ 选修 |

面试一句：生产常见 **不可变 tag（digest 或唯一 build id）**；GitOps 里 values 钉死某一 tag，回滚 = 改回旧 tag 再 Sync。

---

## 7. 和现有 Dockerfile / Helm 的关系

- Dockerfile 仍在 `iot-learn-lab/<service>/Dockerfile`，**构建上下文 = `iot-learn-lab/`**（与 W1 相同）。  
- Helm 当前：`image: device-report-service:0.1.0-SNAPSHOT` + `imagePullPolicy: IfNotPresent`。  
- W9 推 GHCR **不会**自动改 values；集群仍可用本地 load 的旧图，直到 W10 改 image 并处理 `imagePullSecrets` / 公开 Package。

---

## 8. 私有 GHCR 时（概念预告）

若 Package 为 private：

1. 建 `kubernetes.io/dockerconfigjson` Secret  
2. ServiceAccount / Pod `imagePullSecrets`  
3. Argo / Helm values 填完整 `ghcr.io/...`

W9 为降低摩擦，可先把 Package 设为 **内部可见或 public（仅学习仓）**；正式写法放 W10 runbook。

---

## 9. 学习场景 K9（W9 Day 4–5）

| 项 | 内容 |
|----|------|
| **操作** | push 触发（或 `workflow_dispatch`）→ Actions 全绿 → GHCR 能看到三个仓库/三个 tag |
| **预期** | `scenario-k9-github-actions-ci.sh` → `K9 PASS`（查 run / 或文档化 curl GHCR API） |
| **面试** | CI vs CD？为何不用 latest？`packages:write` 干什么？path filter 有何用？ |

---

## 10. W9 故意不做

| 不做 | 留给 |
|------|------|
| CI 自动 commit 改 `values.yaml` | W10 |
| Argo 仅因新镜像滚动（未改 Git） | 反模式；W10 坚持 Git 为真相 |
| 多环境 matrix（staging/prod） | 选修 |
| 签名 / Cosign / SBOM | 选修 |

---

## 11. 下一步

1. 读计划 `docs/superpowers/plans/2026-07-23-stage2-w9-github-actions.md` Task 1→…  
2. [GitHub Actions 文档](https://docs.github.com/en/actions)  
3. [Working with the Container registry](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry)
