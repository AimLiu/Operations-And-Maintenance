# Stage 2 W9：GitHub Actions 构建并推送 GHCR Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 `iot-learn-lab` 建立 **GitHub Actions CI**：`mvn` 校验通过后，构建三服务镜像并推送到 **GHCR**（tag = git short SHA）；产出 CI 段 runbook 与 `scenario-k9-github-actions-ci.sh`。

**Architecture:**  monorepo 内仅对 `iot-learn-lab/**`（及 workflow 自身）触发。Job 串行：`test` → `build-and-push`（matrix 三服务）。镜像名 `ghcr.io/<lowercase-owner>/<service>:<sha>`。**不**自动修改 Helm values、**不**要求 Argo 立刻换图（留给 W10 GitOps 闭环）。本地仍可继续 `minikube image load` 作对照。

**Tech Stack:** GitHub Actions、JDK 21、Maven、Docker Buildx、GHCR（`ghcr.io`）、现有多阶段 Dockerfile

**Spec 来源:** `docs/superpowers/specs/2026-07-13-stage2-k8s-gitops-design.md`（Block E / W9）

**前置知识指南:** `docs/superpowers/guides/2026-07-23-stage2-w9-github-actions.md`

**前置条件（W8 建议完成）：**

- [x] 三服务 Dockerfile 可在 `iot-learn-lab/` 上下文本地 build
- [x] 远程 GitHub 仓库可 push（Argo 已指向该仓，如 `AimLiu/Operations-And-Maintenance`）
- [ ] 仓库 Settings → Actions 可用；有权限写 Packages（个人仓默认可用 `GITHUB_TOKEN` + `packages: write`）
- [ ] 了解 GHCR 包可见性（public / private）；private 时 W10 再配 `imagePullSecrets`

**时间预算:** 1 周 × 8–12h

**W9 边界:**

| W9 做 | W9 不做 |
|-------|---------|
| `.github/workflows/iot-learn-lab-ci.yml` | CI 自动改 `values*.yaml` 的 image（W10） |
| `mvn verify`（或计划约定的测试范围）→ build → push GHCR | 多环境 CD、签名、SBOM |
| short SHA tag +（可选）`sha-<full>` | 仅用 `latest` |
| `stage2-cicd-runbook.md` 的 **CI / GHCR** 章节 | 完整「push → 集群变」闭环（W10 补齐） |
| `scenario-k9-*.sh` | K5 终极演练（Block F） |

---

## 设计透镜（动手前）

| 透镜 | 用法 |
|------|------|
| **Humble/Farley《Continuous Delivery》** | 流水线分阶段；W9 只保证「可重复制品」 |
| **GitOps（W6）** | 集群期望仍在 Git；W9 制品进 GHCR，未写进 Git 就不算部署完成 |
| **不可变基础设施** | SHA tag 钉死构建；避免 `latest` 漂移 |

---

## W9 拓扑

```text
Developer laptop / IDE
        │ git push
        ▼
GitHub（main 或其他约定分支）
        │
        ▼
Actions runner (ubuntu-latest)
   ┌────┴────┐
   │  test   │  mvn -B -pl <modules> -am verify
   └────┬────┘
        ▼
   build-and-push (matrix × 3)
        │  context: iot-learn-lab/
        │  file: <svc>/Dockerfile
        ▼
GHCR: ghcr.io/<owner>/device-report-service:<sha>
      ghcr.io/<owner>/command-dispatch-service:<sha>
      ghcr.io/<owner>/device-report-consumer:<sha>
```

---

## 文件结构（W9 新增 / 修改）

```text
.github/
└── workflows/
    └── iot-learn-lab-ci.yml              # 新建

iot-learn-lab/
├── scripts/stage2/
│   └── scenario-k9-github-actions-ci.sh  # 新建：查最近 run / 文档化验收步骤
└── docs/
    ├── stage2-cicd-runbook.md            # 新建（W9 写 CI；W10 续 CD）
    └── stage2-interview-notes.md         # 追加 W9

docs/superpowers/
├── plans/2026-07-23-stage2-w9-github-actions.md    # 本文件
├── guides/2026-07-23-stage2-w9-github-actions.md
└── specs/2026-07-13-stage2-k8s-gitops-design.md    # 变更记录补 W9 链接
```

**本周一般不改：** 业务 Java、Helm templates（除非为 W10 预留 `image` 拆成 `repository`+`tag`——若做，标为可选 Task）。

---

## 学习场景 K9：CI 出制品

| 项 | 内容 |
|----|------|
| **操作** | 改一处无害文件或 `workflow_dispatch` → Actions 绿 → GHCR 三镜像带同一 short SHA |
| **预期** | `scenario-k9-github-actions-ci.sh` → `K9 PASS` |
| **面试** | CI vs CD？path filter？`packages:write`？为何 short SHA？ |

---

### Task 1: 仓库与 GHCR 前置检查

**Files:** 无代码；文档记录结论

- [ ] **Step 1: 确认远程与 Actions**

```bash
git remote -v
# 浏览器：GitHub → Settings → Actions → General → Allow actions
```

- [ ] **Step 2: 确认 Packages 权限预期**

个人仓库：workflow 内 `permissions.packages: write` + 默认 `GITHUB_TOKEN` 通常足够。  
组织仓：可能需启用「Workflow 写 Packages」策略。

- [ ] **Step 3: 记下 owner 小写名**

```bash
# 例：AimLiu → aimliu
echo "GHCR_OWNER will be lowercase of GitHub user/org"
```

后续镜像：`ghcr.io/aimliu/device-report-service:<sha>`（按你的账号改）。

- [ ] **Step 4: Commit（若有检查清单笔记可写入 runbook 草稿）** — 可与 Task 6 合并

---

### Task 2: 编写 `iot-learn-lab-ci.yml`（骨架 + test job）

**Files:**

- Create: `.github/workflows/iot-learn-lab-ci.yml`

- [ ] **Step 1: 触发与权限**

```yaml
name: iot-learn-lab-ci

on:
  push:
    branches: [main]
    paths:
      - "iot-learn-lab/**"
      - ".github/workflows/iot-learn-lab-ci.yml"
  pull_request:
    branches: [main]
    paths:
      - "iot-learn-lab/**"
      - ".github/workflows/iot-learn-lab-ci.yml"
  workflow_dispatch:

permissions:
  contents: read
  packages: write

defaults:
  run:
    working-directory: iot-learn-lab
```

说明：`pull_request` 上 **push 到 GHCR** 可选关闭（见 Step 3），避免每个 PR 刷包；学习仓可只在 `push`+`workflow_dispatch` 推镜像。

- [ ] **Step 2: test job**

```yaml
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: "21"
          cache: maven
          cache-dependency-path: iot-learn-lab/pom.xml
      - name: Maven verify (three modules)
        run: |
          mvn -B -pl device-report-service,command-dispatch-service,device-report-consumer \
            -am verify
```

若全量测试过慢/缺环境，可临时改为 `package -DskipTests`，但须在 runbook **标明折中**，并争取至少跑单元测试模块。

- [ ] **Step 3: 本地校验 YAML（可选）**

用 [actionlint](https://github.com/rhysd/actionlint) 或先 push 看 Actions 解析错误。

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/iot-learn-lab-ci.yml
git commit -m "$(cat <<'EOF'
ci(stage2-w9): add iot-learn-lab Actions workflow with Maven verify

EOF
)"
```

---

### Task 3: build-and-push job（matrix 三服务 → GHCR）

**Files:**

- Modify: `.github/workflows/iot-learn-lab-ci.yml`

- [ ] **Step 1: 计算短 SHA 与镜像前缀**

```yaml
  build-and-push:
    needs: test
    if: github.event_name != 'pull_request'   # PR 只测不推；可按喜好调整
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        include:
          - service: device-report-service
          - service: command-dispatch-service
          - service: device-report-consumer
    steps:
      - uses: actions/checkout@v4

      - name: Image metadata
        id: meta
        run: |
          OWNER=$(echo "${{ github.repository_owner }}" | tr '[:upper:]' '[:lower:]')
          SHA=$(echo "${{ github.sha }}" | cut -c1-7)
          echo "owner=${OWNER}" >> "$GITHUB_OUTPUT"
          echo "sha=${SHA}" >> "$GITHUB_OUTPUT"
          echo "image=ghcr.io/${OWNER}/${{ matrix.service }}" >> "$GITHUB_OUTPUT"

      - uses: docker/setup-buildx-action@v3

      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - uses: docker/build-push-action@v6
        with:
          context: iot-learn-lab
          file: iot-learn-lab/${{ matrix.service }}/Dockerfile
          push: true
          tags: |
            ${{ steps.meta.outputs.image }}:${{ steps.meta.outputs.sha }}
            ${{ steps.meta.outputs.image }}:sha-${{ github.sha }}
```

- [ ] **Step 2: 首次 `workflow_dispatch` 或 push 验证**

浏览器：Actions → 选中 run → 三服务 build 均成功。  
Packages：仓库页 → Packages（或用户 Packages）出现三个包。

- [ ] **Step 3: 记录完整镜像引用到 runbook**

例：`ghcr.io/aimliu/device-report-service:abc1234`

- [ ] **Step 4: Commit（若有调整）**

```bash
git add .github/workflows/iot-learn-lab-ci.yml
git commit -m "$(cat <<'EOF'
ci(stage2-w9): push three service images to GHCR with short SHA tags

EOF
)"
```

---

### Task 4:（可选）Helm values 预留 repository/tag 字段

**Files:**（选修；不做不阻塞 K9）

- Modify: `iot-learn-lab/infra/helm/iot-learn-lab/values.yaml`
- Modify: templates 中 `image:` 拼接

目标形态（W10 更顺手）：

```yaml
deviceReport:
  image:
    repository: ghcr.io/aimliu/device-report-service
    tag: "0.1.0-SNAPSHOT"   # W10 由 CI 或手工改为 short SHA
```

若本周不改 Chart：W10 直接把 `image:` 字符串换成 `ghcr.io/...:sha` 亦可。

- [ ] **Step 1: 决定做或不做；写入 runbook「W10 准备」**

---

### Task 5: 场景脚本 `scenario-k9-github-actions-ci.sh`

**Files:**

- Create: `iot-learn-lab/scripts/stage2/scenario-k9-github-actions-ci.sh`

- [ ] **Step 1: 最小断言思路**

1. `gh run list --workflow=iot-learn-lab-ci.yml --limit 1` 最近一次 `completed` + `success`（需 [GitHub CLI](https://cli.github.com/) 已登录）  
2. 或：脚本打印人工检查清单并 `exit 0` 当「guided PASS」（学习环境可接受）  
3. 可选：`curl -sH "Authorization: Bearer $GH_TOKEN" https://ghcr.io/v2/...` 探 tag（私有包需 token）

推荐实现（有 `gh` 时）：

```bash
#!/usr/bin/env bash
set -euo pipefail
WF="${WF:-iot-learn-lab-ci.yml}"
echo "== K9: GitHub Actions CI =="
command -v gh >/dev/null || { echo "K9 FAIL: gh CLI required (or document manual check)"; exit 1; }
JSON=$(gh run list --workflow="$WF" --limit 1 --json conclusion,status,displayTitle,url)
echo "$JSON" | head -c 500
echo
echo "$JSON" | grep -q '"conclusion":"success"' || { echo "K9 FAIL: latest run not success"; exit 1; }
echo "K9 PASS: latest ${WF} run success"
echo "Verify GHCR tags manually if needed."
```

- [ ] **Step 2: chmod +x 并试跑**

```bash
chmod +x iot-learn-lab/scripts/stage2/scenario-k9-github-actions-ci.sh
./iot-learn-lab/scripts/stage2/scenario-k9-github-actions-ci.sh
```

- [ ] **Step 3: Commit**

```bash
git add iot-learn-lab/scripts/stage2/scenario-k9-github-actions-ci.sh
git commit -m "$(cat <<'EOF'
feat(stage2-w9): add scenario-k9 GitHub Actions CI check script

EOF
)"
```

---

### Task 6: Runbook + 面试笔记 + Spec 链接

**Files:**

- Create: `iot-learn-lab/docs/stage2-cicd-runbook.md`
- Modify: `iot-learn-lab/docs/stage2-interview-notes.md`
- Modify: `docs/superpowers/specs/2026-07-13-stage2-k8s-gitops-design.md`（变更记录 + W9 计划链接）
- Modify: `iot-learn-lab/README.md`（进度勾到 W9，若有周次表）

- [ ] **Step 1: `stage2-cicd-runbook.md` 最少章节（W9）**

1. CI vs CD / 与 Argo 边界  
2. Workflow 触发条件与 path filter  
3. 镜像命名与 tag  
4. 如何看 Actions / GHCR  
5. 排障：403 packages、owner 大小写、Dockerfile context、Maven 失败  
6. 「下一章 W10」预告：改 values → Sync → pull  

- [ ] **Step 2: interview notes 增加 W9 场景行 + 话术**

- [ ] **Step 3: Spec 变更记录**

```text
| 2026-07-23 | 补充 W9 GitHub Actions/GHCR 计划与指南；场景脚本 k9；CD 闭环留 W10 |
```

并在 Block E W9 下增加：

```text
**实施计划：** docs/superpowers/plans/2026-07-23-stage2-w9-github-actions.md
**前置指南：** docs/superpowers/guides/2026-07-23-stage2-w9-github-actions.md
```

- [ ] **Step 4: Commit**

```bash
git add iot-learn-lab/docs/stage2-cicd-runbook.md \
  iot-learn-lab/docs/stage2-interview-notes.md \
  docs/superpowers/specs/2026-07-13-stage2-k8s-gitops-design.md \
  iot-learn-lab/README.md
git commit -m "$(cat <<'EOF'
docs(stage2-w9): add CI/CD runbook CI section and W9 interview notes

EOF
)"
```

---

## W9 完成标准（Checklist）

- [ ] `iot-learn-lab-ci.yml` 在 `main`（或约定分支）可手动/推送触发  
- [ ] `test` job 绿  
- [ ] GHCR 存在三服务镜像，带同一 short SHA tag  
- [ ] PR 策略已文档化（测或不推包）  
- [ ] `scenario-k9-*.sh` → `K9 PASS`（或等价人工清单已记录）  
- [ ] `stage2-cicd-runbook.md` CI 章节可读；interview notes 已更新  
- [ ] **未**要求集群已换成 GHCR 镜像（那是 W10）

---

## W9 面试话术速记

> 「CI 保证每次提交能产出可追溯制品；我们用 Actions 跑 Maven，再把三个服务的多阶段镜像推到 GHCR，tag 用 commit short SHA。CD/GitOps 是下一步：把 tag 写进 Helm values，让 Argo CD Sync，而不是让 CI 直接 kubectl set image——那样 Git 就不是真相源了。」

| 问题 | 要点 |
|------|------|
| 为何不用 latest？ | 不可追溯、回滚说不清 |
| path filter？ | 省分钟；避免改 docs 误触发重构建 |
| packages:write？ | `GITHUB_TOKEN` 推 GHCR 所需 |
| 和 minikube load 关系？ | W9 后制品在云端；学习机仍可 load 对照，生产路径走仓库拉取 |

---

## 排障

| 现象 | 可能原因 | 处理 |
|------|----------|------|
| `denied: permission_denied` 推 GHCR | 缺 `packages: write` / 组织策略 | 查 workflow permissions；组织允许 Actions 写 package |
| 镜像名 404 / invalid | owner 未小写 | `tr '[:upper:]' '[:lower:]'` |
| build 找不到父 POM | context 不是 `iot-learn-lab` | `context:` / `file:` 路径对齐 W1 |
| Maven 失败 | 测试依赖中间件 | 修测试或 `-DskipTests` 并文档化 |
| Actions 未触发 | paths 未匹配 / 分支不对 | `workflow_dispatch`；检查 paths |
| Package 有但集群拉不下 | private + 无 pull secret | W10 配 Secret；或学习期改 public |

---

## Spec 覆盖映射

| Spec 要求（W9） | 本计划 |
|-----------------|--------|
| `.github/workflows/iot-learn-lab-ci.yml` | Task 2–3 |
| mvn → docker build → push GHCR | Task 2–3 |
| Tag short hash | Task 3 |
| 场景 / 文档 | Task 5–6 |
| 改 values + Argo 闭环 | **不做（W10）** |

---

## 执行方式建议

计划已写好。实施时可：

1. **Subagent-driven**（推荐）— 按 Task 逐个实现并审查  
2. **本会话内联** — 从 Task 1 开始  

你说「开始 Task 1」或「按 W9 计划实施」即可继续写 workflow 实体文件。
