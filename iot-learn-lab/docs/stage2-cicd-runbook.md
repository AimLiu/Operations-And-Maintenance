# Stage 2 CI/CD Runbook

**对照：** W9 计划 `docs/superpowers/plans/2026-07-23-stage2-w9-github-actions.md`  
**指南：** `docs/superpowers/guides/2026-07-23-stage2-w9-github-actions.md`  
**仓库：** `AimLiu/Operations-And-Maintenance` · 分支 **`main`**  
**Workflow：** `.github/workflows/iot-learn-lab-ci.yml`

> **W9（本章）：** CI = 测过 + 镜像进 GHCR。  
> **W10（下章）：** 改 Helm image → Argo Sync → 集群用 GHCR（结束本机 `minikube image load` 主路径）。

---

## 1. CI vs CD / 与 Argo 的边界

```text
W9 CI                          W10 CD / GitOps
────────                       ────────────────
push → Actions                 Git 里写明 image: ghcr.io/...:sha
  test (mvn verify)                 ↓
  build-and-push → GHCR        Argo 对比 Git vs 集群 → Sync
                                     ↓
                               Pod 拉取新镜像
```

| | W9 已完成 | W10 要做 |
|--|-----------|----------|
| 制品 | ✅ GHCR 三服务短 SHA tag | 让 Chart **引用**这些 tag |
| 集群 | ❌ 不自动变 | ✅ Argo Sync 后变 |
| 本机 load | 仍可作对照 | 主路径应能去掉 |

**面试一句：** CI 保证可追溯制品；CD/GitOps 把「用哪张制品」写进 Git，由 Argo 调和——不是 CI 直接 `kubectl set image`。

---

## 2. Workflow 何时触发

| 事件 | 行为 |
|------|------|
| `push` → `main`，且改动 `iot-learn-lab/**` 或本 workflow | 跑 `test` + `build-and-push` |
| `pull_request` → `main`（同上 paths） | 只跑 `test`（不推 GHCR） |
| `workflow_dispatch` | 手动全跑（含推镜像） |

**path filter：** 只改无关文档可能不触发。要强制跑：Actions → `iot-learn-lab-ci` → Run workflow。

**权限：** `contents: read` + `packages: write`（推 GHCR）。

---

## 3. 镜像命名与 tag

```text
ghcr.io/<小写owner>/<service>:<short-sha>
ghcr.io/<小写owner>/<service>:sha-<full-sha>
```

例（owner = `AimLiu` → `aimliu`）：

```text
ghcr.io/aimliu/device-report-service:a1b2c3d
ghcr.io/aimliu/command-dispatch-service:a1b2c3d
ghcr.io/aimliu/device-report-consumer:a1b2c3d
```

| 服务 | 镜像名 |
|------|--------|
| device-report-service | `ghcr.io/aimliu/device-report-service` |
| command-dispatch-service | `ghcr.io/aimliu/command-dispatch-service` |
| device-report-consumer | `ghcr.io/aimliu/device-report-consumer` |

短 SHA = `github.sha` 前 7 位。同一 run 三个服务 **共用** 同一 short SHA。

查看 Packages：GitHub 仓库右侧 **Packages**，或用户主页 Packages。

---

## 4. 如何看 Actions / 成功长什么样

1. 打开 [Actions](https://github.com/AimLiu/Operations-And-Maintenance/actions) → 选中一次 run。  
2. 左侧应见绿勾：
   - `test`
   - `build-and-push (device-report-service)`
   - `build-and-push (command-dispatch-service)`
   - `build-and-push (device-report-consumer)`
3. Summary 里 Node.js deprecated 警告可忽略。  
4. Artifacts 里的 `.dockerbuild` 是构建记录，**不是**完整镜像；镜像在 **GHCR**。

成功示例 run（学习记录）：  
https://github.com/AimLiu/Operations-And-Maintenance/actions/runs/30192109160

场景脚本（需 `gh` 登录）：

```bash
./iot-learn-lab/scripts/stage2/scenario-k9-github-actions-ci.sh
# 期望：K9 PASS
```

---

## 5. Jobs 在干什么（对照 YAML）

### `test`

- 云端 Ubuntu + JDK 21  
- `mvn -B -pl <三模块> -am verify`  
- 失败则整次 CI 失败，**不会**推镜像  

已知曾踩坑（已修）：

- Nacos `import-check` → 测试加 `import-check.enabled=false`  
- `DeviceReportServiceTest` 缺 mock `CanaryBugConfig`  
- 断言笔误 `device-oo1` → `device-001`

### `build-and-push`（`needs: test`）

- matrix × 3 服务  
- 登录 `ghcr.io`（`GITHUB_TOKEN`）  
- `docker/build-push-action`：`context=iot-learn-lab`，`push: true`  
- Dockerfile 内仍会 `mvn package`（镜像构建阶段再编 jar）

---

## 6. 排障

| 现象 | 可能原因 | 处理 |
|------|----------|------|
| Actions 未触发 | paths / 分支不是 `main` | `workflow_dispatch`；检查 paths |
| `test` 红 | 单测/Nacos/依赖 | 看 Surefire 日志；本地 `mvn -pl ... verify` |
| 推 GHCR `denied` | 缺 `packages: write` / 组织策略 | 查 workflow permissions |
| 镜像名无效 | owner 未小写 | workflow 里已 `tr` 小写 |
| build 找不到 POM | context 错 | 必须 `iot-learn-lab` |
| Package 有、集群拉不下 | private + 无 pull secret | W10 配 Secret，或学习期 Package 公开 |
| 以为 CI 绿集群就新了 | W9 不改 values | 做 W10 |

---

## 7. 下一章 W10 预告（构建一次 → 部署目标）

```text
1. Helm values 改为 ghcr.io/aimliu/<svc>:<short-sha>
2. （若 private）imagePullSecrets
3. commit → Argo Sync（auto 或手动）
4. kubectl 确认 Pod 镜像与 Ready
5. Ingress / Jaeger 冒烟
```

原则：**同一 SHA 制品**；用 Git 声明「集群用哪张」；不必本机 `minikube image load` 作为主路径。  
多环境时：test/prod 两套 values，先改 test，再晋升同一 tag 到 prod（不必再 build）。

---

## 8. 相关文件

| 路径 | 说明 |
|------|------|
| `.github/workflows/iot-learn-lab-ci.yml` | CI 定义 |
| `iot-learn-lab/*/Dockerfile` | 多阶段构建 |
| `scripts/stage2/scenario-k9-github-actions-ci.sh` | K9 验收 |
| `infra/argocd/application-iot-learn-lab.yaml` | W10 仍靠它 Sync Chart |
| `infra/helm/iot-learn-lab/values*.yaml` | W10 改 image |
