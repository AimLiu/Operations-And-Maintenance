# Stage 2 W1 前置知识：从本地 Docker 到 minikube 上的第一张 YAML

**读者：** 会写一点 Dockerfile、用过 WSL Docker，但几乎没在真实项目里亲手 `kubectl apply` 过的人  
**范围：** 只覆盖 Stage 2 W1（尤其 Task 5–6）会碰到的概念  
**对照计划：** `docs/superpowers/plans/2026-07-13-stage2-w1-minikube-dockerfile.md`  
**不讲：** Helm、Argo CD、Ingress 细则、CNI 底层（W3+ 再展开）

读完你应能回答四件事：

1. `kubectl apply -f deployment.yaml` 之后，集群里发生了什么  
2. Pod、Deployment、Service、ConfigMap、Namespace 各自干什么  
3. 为什么本地 `docker build` 了，还要 `minikube image load`  
4. Task 5 为什么「只 build 不部署」、Task 6 那四份 YAML 怎么串起来  

---

## 1. 先看一串你已经在敲的命令

```bash
# Task 5：把另外两个服务也打成镜像（先不部署）
docker build -f command-dispatch-service/Dockerfile -t command-dispatch-service:0.1.0-SNAPSHOT .
docker build -f device-report-consumer/Dockerfile -t device-report-consumer:0.1.0-SNAPSHOT .

# Task 6：往集群里声明「我想要这些对象」
kubectl apply -f iot-learn-lab/infra/k8s/namespace.yaml
kubectl apply -f iot-learn-lab/infra/k8s/device-report/configmap-env.yaml
kubectl apply -f iot-learn-lab/infra/k8s/device-report/deployment.yaml
kubectl apply -f iot-learn-lab/infra/k8s/device-report/service.yaml

kubectl rollout status deployment/device-report-service -n iot-learn --timeout=180s
kubectl get pods -n iot-learn -o wide
```

成功时你大概会看到：

```text
namespace/iot-learn created
configmap/device-report-middleware created
deployment.apps/device-report-service created
service/device-report-service created
deployment "device-report-service" successfully rolled out

NAME                                  READY   STATUS    RESTARTS   AGE
device-report-service-xxxxx-yyyyy     1/1     Running   0          30s
```

下面所有概念，都是在解释这一串命令背后发生了什么。

---

## 2. 和你熟悉的世界对比一下

| 你以前大概这么做 | W1 在 K8s 里这么做 |
|------------------|-------------------|
| IDEA / `java -jar` 启动一个服务 | 集群按 YAML **拉起容器** |
| `docker run -e DB_HOST=...` | ConfigMap / 环境变量注入 |
| 改端口、改副本 → 手动重启容器 | 改 Deployment → `kubectl apply` → 滚动更新 |
| `localhost:8765` 自测 | 先 `kubectl port-forward`（W1）；Ingress 留给后面 |
| Compose 里写一堆 service | Namespace 里放 Deployment + Service |

K8s **不是**「换一个更高级的 Docker Compose」这么简单，但对 W1 来说，你可以先把它当成：

> **用 YAML 声明我想要几个什么样子的容器副本，以及别人怎么在集群里找到它们；集群负责把状态兜住。**

---

## 3. 工具三角：minikube / kubectl / 镜像（再压一遍）

```text
minikube  → 在本机（WSL Docker）里搭一个「玩具集群」
kubectl   → 对着这个集群下指令（增删改查资源）
镜像      → 真正跑起来的程序包装；K8s 只认镜像，不认你本地的 Maven target/
```

要点：

- **minikube 不替代 kubectl**；前者建环境，后者操作环境。  
- **WSL 的 Docker 和 minikube 节点里的 Docker 是两套镜像仓库**。  
  在 WSL 里 `docker build` 成功 ≠ Pod 能拉到这张图。  
  所以本地镜像要：`minikube image load <image:tag>`。  
- 集群停了（`minikube status` 显示 Stopped）时，`kubectl` / `minikube ssh` 都会失败；先 `minikube start`。

更细的「localhost:8080 不是端口冲突」「kicbase 多个映射端口」写在 W1 计划的前置知识章节；本篇不重复。

---

## 4. W1 对象模型：你只需要认清这 6 个词

### 4.1 Namespace —— 逻辑分区

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: iot-learn
```

就像给实验资源开一个文件夹，名字叫 `iot-learn`。  
后面所有命令带 `-n iot-learn`，就是只看这个文件夹里的东西。

```bash
kubectl get all -n iot-learn
```

`default`、`kube-system` 也是 Namespace；系统组件在 `kube-system`，别随便删。

### 4.2 Pod —— 最小调度单位

Pod ≈ 「一起调度的一组容器」（W1 每个 Pod 里基本就 1 个业务容器）。

你很少直接手写长久存活的裸 Pod。W1 的业务 Pod 是 **Deployment 自动创建** 的，名字类似：

```text
device-report-service-699dc97f57-bf48w
                 │              │
                 │              └── Pod 随机后缀
                 └── ReplicaSet 哈希
```

```bash
kubectl get pods -n iot-learn -o wide
kubectl describe pod -n iot-learn -l app=device-report-service
kubectl logs -n iot-learn -l app=device-report-service --tail=100
```

`CrashLoopBackOff` = 容器反复启动失败。先 `logs` / `logs --previous`，再猜网络。

### 4.3 Deployment —— 「我要 N 个这种 Pod」

Deployment 描述：

- 用哪张镜像  
- 要几个副本（`replicas`）  
- 容器端口、环境变量、探针、资源限制  
- **标签**（后面 Service 靠标签找人或）

集群还接了一层你暂时看不见却很关键的东西：**ReplicaSet**。  
可以粗略记：Deployment 管版本与滚动更新；ReplicaSet 保证「当前这个版本始终有 N 个 Pod」。

```bash
kubectl get deploy,rs,pods -n iot-learn
kubectl rollout status deployment/device-report-service -n iot-learn
kubectl rollout restart deployment/device-report-service -n iot-learn   # 强制重建 Pod（换镜像后常用）
```

### 4.4 Service —— 稳定的访问入口（集群内 DNS）

Pod IP 会变（重启换 IP）。Service 提供一个**稳定的名字 + 虚拟 IP（ClusterIP）**，按标签把流量转到后端 Pod。

W1 里是 `ClusterIP`：只在集群内部可达。你在笔记本上要测 HTTP，一般：

```bash
kubectl port-forward -n iot-learn svc/device-report-service 8765:8765
curl http://127.0.0.1:8765/actuator/health
```

`port-forward` = 临时隧道，不是生产入口（Ingress 是后话）。

### 4.5 ConfigMap —— 非密钥配置

```yaml
data:
  DB_HOST: "host.minikube.internal"
  REDIS_HOST: "host.minikube.internal"
  SPRING_PROFILES_ACTIVE: "k8s"
```

Deployment 里：

```yaml
envFrom:
  - configMapRef:
      name: device-report-middleware
```

效果接近：`docker run -e DB_HOST=... -e REDIS_HOST=...`。  
W1 密码也写在 ConfigMap 里是为了省事；生产应走 Secret，这里先别抬杠。

### 4.6 它们怎么套在一起

```text
Namespace: iot-learn
│
├─ ConfigMap: device-report-middleware     ← 环境变量来源
│
├─ Deployment: device-report-service
│     └─ 创建 Pod（跑镜像 device-report-service:0.1.0-SNAPSHOT）
│           env ← REST ConfigMap
│
└─ Service: device-report-service
      selector: app=device-report-service  ← 用标签找到 Pod
      ClusterIP → Pod:8765
```

---

## 5. 标签（label）和选择器（selector）：真正的「胶水」

Deployment 给 Pod 打标签：

```yaml
template:
  metadata:
    labels:
      app: device-report-service
```

Service 用选择器找它们：

```yaml
selector:
  app: device-report-service
```

**名字相同 ≠ 自动关联。** 关联靠的是 label 匹配。  
`kubectl get pods -l app=device-report-service` 也是同一套机制。

---

## 6. 镜像相关：Task 5 在干什么

### 6.1 Task 5 在业务上的意义

Task 5 给另外两个模块补 Dockerfile，并可选地 `docker build`。

W1 **只把 `device-report-service` 部署进集群**。  
另外两张镜像是为了：

- 验证 Dockerfile 能编过  
- W2 上三服务时少走弯路  

所以 Task 5 结束时，WSL 里有镜像即可；**不必** `minikube image load` 那两张（除非你闲得发慌想先导入）。

### 6.2 为什么 Deployment 要写 `imagePullPolicy: IfNotPresent`

```yaml
image: device-report-service:0.1.0-SNAPSHOT
imagePullPolicy: IfNotPresent
```

含义：

- 节点上**已有**这张 tag → 直接用，不去远程仓库拉  
- 没有 → 才尝试 pull（本地学习镜像通常没推到 registry，pull 会挂）

配合：

```bash
docker build ... -t device-report-service:0.1.0-SNAPSHOT .
minikube image load device-report-service:0.1.0-SNAPSHOT
kubectl rollout restart deployment/device-report-service -n iot-learn
```

**同一 tag 覆盖构建后，一定要 load + restart**，否则 Pod 还在用旧层。  
你遇到的 `/app/log` 写失败，就是旧镜像里没预建日志目录的典型例子。

### 6.3 Dockerfile 在 W1 只需记住这几句（你已熟悉可略读）

- 多阶段：builder 用 JDK + Maven 打包；运行期用 JRE，镜像更小  
- `USER spring`：非 root 更安全，但 **要先建好 `/app/log` 并 chown**，否则 logback 文件 appender 直接把进程打崩  
- `EXPOSE 8765`：文档性声明；真正开端口靠 Deployment 的 `containerPort` + Service  

---

## 7. Task 6 逐步拆开：每一份 YAML 在声明什么

### 7.1 Step：创建 Namespace

```bash
kubectl apply -f iot-learn-lab/infra/k8s/namespace.yaml
```

声明实验命名空间。幂等：再 apply 一次通常是 `configured` / `unchanged`，不会炸。

### 7.2 Step：ConfigMap——把中间件地址塞进环境

关键字段：

| 键 | 值（W1） | 为什么 |
|----|----------|--------|
| `DB_HOST` 等 | `host.minikube.internal` | Pod 访问 **WSL Docker** 里的 Postgres/Redis/Nacos |
| `SPRING_PROFILES_ACTIVE` | `k8s` | 激活 `application-k8s.yml` |

**不要**填 `192.168.16.1`（那是 WSL→Windows）。  
Windows 访问 WSL 的 `192.168.19.64` 也不是 Pod 首选。

部署前自检：

```bash
# WSL：中间件在不在
nc -zv localhost 5432

# minikube 节点：Pod 视角能不能到
minikube ssh -- nc -zv host.minikube.internal 5432
```

### 7.3 Step：Deployment——声明「要一个这样的 Pod」

挑字段讲（对应你仓库里的 `deployment.yaml`）：

| 字段 | 作用 |
|------|------|
| `replicas: 1` | 要 1 个副本 |
| `selector.matchLabels` | Deployment 认领哪些 Pod（必须和 template.labels 对上） |
| `containers[].image` | 跑哪张镜像 |
| `imagePullPolicy: IfNotPresent` | 优先用节点本地镜像 |
| `containerPort: 8765` | 容器监听端口（给探针/Service 对齐） |
| `envFrom.configMapRef` | 整包注入 ConfigMap 键值 |
| `readinessProbe` | **就绪**：通了才进 Service；失败则暂时不接流量 |
| `livenessProbe` | **存活**：僵死了就重启容器 |
| `resources.requests/limits` | 调度与上限；JVM 配了 `MaxRAMPercentage` 时更要对齐 |

**readiness vs liveness（面试常问）：**

- readiness 失败 → 流量先别打过来，**不一定杀进程**  
- liveness 失败 → kubelet **重启容器**  
- W1 探针打 Spring Boot：`/actuator/health/readiness` 与 `/liveness`（需 `management.endpoint.health.probes.enabled=true`，已在 `application-k8s.yml`）

### 7.4 Step：Service——给 Pod 一个稳定名字

| 字段 | 作用 |
|------|------|
| `type: ClusterIP` | 仅集群内访问 |
| `selector.app` | 选中带该 label 的 Pod |
| `port` → `targetPort` | Service 端口 → 容器端口（W1 都是 8765） |

集群内其它服务以后会用类似：

```text
http://device-report-service.iot-learn.svc.cluster.local:8765
```

W1 你用 port-forward 就够。

### 7.5 Step：等待 Ready

```bash
kubectl rollout status deployment/device-report-service -n iot-learn --timeout=180s
```

含义：等到新副本达到「可用」（含 readiness）。  
超时了不要瞎重启整个 minikube，按下一节排障。

---

## 7A. 混合部署特有坑：Nacos「端口通，人连错」

先看一段真实日志（W1 实操）：

```text
nc host.minikube.internal 8848 → succeeded
nc host.minikube.internal 9848 → succeeded

# 但 Pod 日志仍是：
grpc client connection server:127.0.0.1 ip,serverPort:9848
Fail to connect ... serverIp = '127.0.0.1', server main port = 8848
*_config-0 ... Client not connected, current status:STARTING
```

### 为什么会出现

两层叠加：

**服务端宣告错：**  
Nacos 2.x 客户端第一次用你配置的 `server-addr` 联系服务端后，会拿到一份「成员 / RPC 地址」。Docker 单机若未正确设置 `nacos.inetutils.ip-address`，这份地址经常是 **`127.0.0.1`**。对 Windows/WSL 本机进程，「本机 127.0.0.1」刚好是 Nacos；对 **Pod**，「127.0.0.1」是容器自己 → `9848 Connection refused`。

**`-D` 放错位置会白改：**  
`NACOS_SERVER_IP` 只注入 `-Dnacos.server.ip`（控制台 URL 好看）。真正影响客户端拿到的地址的是 `-Dnacos.inetutils.ip-address=...`。若写在 compose 的 `JAVA_OPT_EXT`，官方启动脚本会把它拼在 **`-jar` 后面**，`-D` 进不了 JVM。

**客户端还强行开了配置中心：**  
`spring.config.import: optional:nacos:...` 会起 `*_config-0` 线程；`config.enabled=false` 管不住它。Phase 4 的导入应只留在 `application-v2.yml`。

### W1 怎么处理

| 侧 | 做法 |
|----|------|
| Nacos compose | `JAVA_OPT: "-Dnacos.inetutils.ip-address=192.168.19.64"`（**不要**用 `JAVA_OPT_EXT` 传 `-D`）+ `NACOS_SERVER_IP` |
| 应用 | 默认去掉 `optional:nacos`；`application-k8s.yml` W1 关闭 discovery/config |
| ConfigMap | `NACOS_ADDR=192.168.19.64:8848` |
| 操作 | 改 Nacos 后 **restart Deployment**；改 yml 后 **rebuild + image rm/load** |

完整说明：`iot-learn-lab/infra/k8s/README.md` 中「踩坑实录：Nacos」。

---

## 8. `kubectl apply` 到底做了什么

```text
你的 YAML（期望状态）
        │
        ▼
   kubectl apply
        │
        ▼
   API Server 写入 etcd
        │
        ▼
控制器（Deployment 控制器等）不断调和：
   「现在有 0 个 Pod」→ 「那就创建一个」
        │
        ▼
   kubelet 在 minikube 节点上拉镜像、起容器、跑探针
```

声明式的好处：YAML 就是真相源；改完再 apply，不必记住一长串 imperative 命令。

常用查看：

```bash
kubectl get ns
kubectl get cm,deploy,svc,pods -n iot-learn
kubectl describe deploy device-report-service -n iot-learn
kubectl get events -n iot-learn --sort-by='.lastTimestamp'
```

删除实验资源（慎用）：

```bash
kubectl delete -f iot-learn-lab/infra/k8s/device-report/
# 或删整个命名空间：
# kubectl delete ns iot-learn
```

---

## 9. CrashLoopBackOff 时怎么查（按这个顺序）

```bash
# 1) 是不是没镜像 / 拉镜像失败？
kubectl describe pod -n iot-learn -l app=device-report-service
# 看 Events：ImagePullBackOff / ErrImageNeverPull / Created / Started / BackOff

# 2) 进程为什么退出？（必看）
kubectl logs -n iot-learn -l app=device-report-service --tail=100
kubectl logs -n iot-learn -l app=device-report-service --previous --tail=100

# 3) 配置对不对？
kubectl get cm device-report-middleware -n iot-learn -o yaml
```

W1 真实踩过的两种：

| 日志特征 | 根因 | 处理 |
|----------|------|------|
| `/app/log/... No such file` | 非 root 写不了日志目录 | Dockerfile 预建 `/app/log` → rebuild → `image load` → `rollout restart` |
| DB 连不上 / JDBC timeout | 中间件地址或网络 | ConfigMap 用 `host.minikube.internal`；`minikube ssh -- nc -zv ... 5432` |

**不要**一上来怀疑「要不要改 8080」。那是集群根本没起来时 kubectl 的默认地址。

---

## 10. 混合架构网络（Task 6 ConfigMap 为何这么写）

```text
┌─ minikube Pod：device-report-service ─────────────────┐
│  DB_HOST=host.minikube.internal                         │
└───────────────────────────┬─────────────────────────────┘
                            │
              host.minikube.internal（常解析为 192.168.49.1）
                            │
┌───────────────────────────▼─────────────────────────────┐
│  WSL Docker：postgres:5432 / redis:6379 / nacos:8848    │
└─────────────────────────────────────────────────────────┘
```

口诀（Stage 2 版）：

| 地址 | 方向 | 给谁用 |
|------|------|--------|
| `192.168.16.1` | WSL → Windows | Phase 1–5 APISIX upstream；**别进 ConfigMap** |
| `192.168.19.64` | Windows → WSL | Windows 浏览器访问中间件 |
| `host.minikube.internal` | Pod → WSL Docker | **Task 6 ConfigMap 首选** |
| `localhost`（在 WSL 终端） | WSL → 本机 Docker | 人肉自检中间件 |

在 WSL 本机 `mvn spring-boot:run --spring.profiles.active=k8s` 时，`host.minikube.internal` 不好使，要把 `DB_HOST` / `REDIS_HOST` / `NACOS_ADDR` / `SENTINEL_DASHBOARD` 全部覆盖成 `localhost` 或 `192.168.19.64`。  
Pod 里才用 ConfigMap 那套。

---

## 11. Task 5–6 操作清单（对照执行）

### Task 5

1. 写好两个模块的 Dockerfile / `.dockerignore`（与 `device-report-service` 同模式即可）  
2. （可选）在 `iot-learn-lab` 根目录 build：  
   `docker build -f command-dispatch-service/Dockerfile -t command-dispatch-service:0.1.0-SNAPSHOT .`  
   `docker build -f device-report-consumer/Dockerfile -t device-report-consumer:0.1.0-SNAPSHOT .`  
3. W1 **停**；部署留给 W2  

### Task 6

1. 确认 minikube Running：`minikube status`  
2. 确认业务镜像已在节点：`minikube image load device-report-service:0.1.0-SNAPSHOT`  
3. 确认中间件：`minikube ssh -- nc -zv host.minikube.internal 5432`  
4. `kubectl apply` 四份 YAML（顺序：ns → configmap → deploy → svc）  
5. `kubectl rollout status ...`  
6. `kubectl get pods -n iot-learn` 期望 `1/1 Running`  
7. （下一步 Task 7）port-forward + curl health / 上报  

---

## 12. 命令速查（贴终端旁）

```bash
minikube status
minikube start --driver=docker   # 停了再起
minikube image load <image:tag>
minikube ssh -- docker images | grep device-report
minikube ssh -- nc -zv host.minikube.internal 5432

kubectl get nodes
kubectl get all -n iot-learn
kubectl apply -f <file-or-dir>
kubectl describe pod -n iot-learn -l app=device-report-service
kubectl logs -n iot-learn -l app=device-report-service --tail=100
kubectl logs -n iot-learn -l app=device-report-service --previous --tail=100
kubectl rollout restart deployment/device-report-service -n iot-learn
kubectl port-forward -n iot-learn svc/device-report-service 8765:8765
```

---

## 13. W1 故意还没碰的东西

| 概念 | 何时 |
|------|------|
| Ingress / 对外域名 | W3 |
| Helm Chart | W4–W5 |
| Argo CD / Rollouts | W6–W7 |
| Secret（正经密钥） | 以后加固时 |
| StatefulSet / PVC 跑数据库 | 选修；当前中间件仍在 WSL Docker |

先把手弄脏：一份 Deployment 真的 Running，比背完官方术语有用。

---

## 14. 带走的五句话

1. **kubectl 声明期望；控制器把集群推到那个期望。**  
2. **Pod 会换，Service 按标签找人。**  
3. **ConfigMap 喂环境变量；Pod 连中间件用 `host.minikube.internal`。**  
4. **WSL Docker ≠ minikube 镜像库；改镜像后 load + restart。**  
5. **CrashLoop 先看 logs，再查网络——很多时候是应用自己崩了（例如 `/app/log`）。**

下一步照 W1 Task 7 的 `scenario-k1-k8s-baseline.sh`：port-forward → health → POST 上报。  
若某一步结果和预期不一致，把 `kubectl get pods` + `kubectl logs --tail=80` 贴出来，从日志往上游追即可。
