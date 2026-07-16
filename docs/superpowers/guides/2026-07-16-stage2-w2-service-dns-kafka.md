# Stage 2 W2 前置知识：Service DNS、Feign URL 与 Kafka advertised

**读者：** 已完成 W1（单服务上集群），知道 Pod / Deployment / Service / ConfigMap，但还没在集群里做过服务间调用  
**范围：** 只覆盖 Stage 2 W2（三服务 + Feign + Kafka）会碰到的概念  
**对照计划：** `docs/superpowers/plans/2026-07-16-stage2-w2-three-services.md`  
**不讲：** Ingress、Helm、Argo、Prometheus ServiceMonitor（W3+）

读完你应能回答五件事：

1. 同 Namespace 里，一个 Pod 怎么用名字找到另一个 Service  
2. 为什么 W2 的 Feign 继续用 `url=` + `DISPATCH_BASE_URL`，而不开 Nacos 发现  
3. Kafka「端口通了」为什么业务仍可能连 `localhost:9092` 失败  
4. ConfigMap 改完为什么必须 `rollout restart`  
5. K2 脚本要打哪三条 API，分别验证什么  

---

## 1. 先看一串你马上要敲的命令

```bash
# 修正 Kafka advertised（Task 1）
cd iot-learn-lab/infra/kafka && docker compose up -d --force-recreate

# 部署另两个服务（Task 5–6）
kubectl apply -f iot-learn-lab/infra/k8s/command-dispatch/
kubectl apply -f iot-learn-lab/infra/k8s/device-report-consumer/

# 让 report 读到新的 DISPATCH_BASE_URL / KAFKA_BOOTSTRAP（Task 4）
kubectl apply -f iot-learn-lab/infra/k8s/device-report/configmap-env.yaml
kubectl rollout restart deployment/device-report-service -n iot-learn

# 验证（Task 7）
iot-learn-lab/scripts/stage2/scenario-k2-three-services.sh
```

成功时大致会看到：

```text
deployment "command-dispatch-service" successfully rolled out
deployment "device-report-consumer" successfully rolled out
...
K2 PASS: sync + Feign + async 路径基本打通
```

下面所有概念，都是在解释：**为什么要多两个 Deployment，以及流量怎么在集群里拐弯。**

---

## 2. 和 W1 / Phase 1–5 对比

| 以前 | W2 |
|------|-----|
| IDEA 起三个 Java 进程，互相 `localhost:8767` | 三个 Pod；互相用 **Service 名** |
| Feign → Nacos 找 `command-dispatch-service` | Feign → ConfigMap 注入的 **固定 URL**（K8s DNS） |
| Kafka bootstrap `192.168.19.64:9092`（Windows） | Pod 里 bootstrap 可用 `host.minikube.internal:9092`，但 **advertised 必须是 Pod 可达 IP** |
| Phase 5 异步削峰在本机演示 | 同一套 `reports-async` + consumer，跑在集群里 |

W2 不是重写业务，而是把 **「进程怎么找到对方」** 从本机端口换成集群原语。

---

## 3. Service DNS：集群内的「电话簿」

### 3.1 短名 vs FQDN

同 Namespace（本实验都是 `iot-learn`）：

```text
http://command-dispatch-service:8767
```

完整 FQDN（跨 Namespace 才必须写全）：

```text
http://command-dispatch-service.iot-learn.svc.cluster.local:8767
```

口诀：

> **Service 的 `metadata.name` + 端口 = 集群内可达地址。**  
> 端口是 Service 的 `port`，不是随便写宿主机端口。

### 3.2 流量怎么走

```text
device-report Pod
    │  DNS 查询 command-dispatch-service
    ▼
kube-dns / CoreDNS  →  ClusterIP（虚 IP）
    │
    ▼
kube-proxy / iptables或ipvs  →  某个 Ready 的 dispatch Pod:8767
```

你 **不用** 知道 dispatch Pod 的 IP 会变；Deployment 滚动时，Service 的 selector 会继续指向新 Pod。

### 3.3 和「容器 IP / Pod IP」的区别

| 地址 | 稳不稳 | 谁用 |
|------|--------|------|
| Pod IP | 重建就变 | 调试临时 curl；**业务代码别写死** |
| Service ClusterIP | 相对稳定（删 Service 才变） | 集群内访问入口 |
| Service DNS 名 | 最稳（名字固定） | **Feign / 配置里该写这个** |

---

## 4. Feign：为什么还是 `url=`，不开 Nacos？

### 4.1 代码里已经写死了「可配置 URL」

```java
@FeignClient(name = "command-dispatch-service",
        url = "${dispatch.base-url:http://localhost:8767}",
        fallback = DispatchFallbackHandler.class)
```

`name` 在开了服务发现时用于从注册中心解析；**一旦写了 `url`，Feign 优先用这个 URL**。

W2 通过环境变量：

```text
DISPATCH_BASE_URL=http://command-dispatch-service:8767
  → dispatch.base-url
  → Feign 直连 K8s Service
```

### 4.2 为什么不在 W2 打开 Nacos discovery？

W1 README 已踩过坑：Docker 单机 Nacos 若把成员地址宣告成 `127.0.0.1`，Pod 里的客户端会去连 **自己 Pod 的 9848**。  
修服务端 `nacos.inetutils.ip-address` 可以解决，但 W2 目标是 **先证明集群内调用**，不必同时背两个故障面。

面试话术：

> 「混合部署阶段，服务发现用 K8s DNS；Nacos 留给对照实验或中间件迁入集群之后。」

### 4.3 失败时你会看到什么？

| 现象 | 含义 |
|------|------|
| with-dispatch 很快返回且像降级 | 多半触发了 Sentinel fallback（连不上 / 超时） |
| 连接 `localhost:8767` | ConfigMap 没注入或旧 Pod 未 restart |
| UnknownHostException `command-dispatch-service` | Service 未创建，或不在同一 Namespace |

---

## 5. Kafka：bootstrap ≠ 真正连上的地址

### 5.1 两跳连接

```text
① 客户端连接 bootstrap（你配置的 KAFKA_BOOTSTRAP）
        │
        ▼
② broker 在 metadata 里返回 advertised.listeners 里的地址
        │
        ▼
③ 客户端改连「宣告地址」拉消息 / 发消息
```

只做 `nc -zv host.minikube.internal 9092` **只能证明第 ① 步的 TCP 通**，不能证明第 ③ 步。

### 5.2 为什么 `localhost` 在 Pod 里是毒药

旧配置常见：

```yaml
KAFKA_ADVERTISED_LISTENERS: "...,PLAINTEXT_HOST://localhost:9092"
```

| 客户端在哪 | metadata 返回 localhost 时 |
|------------|---------------------------|
| Windows / WSL 宿主机 | 有时碰巧还能用（本机端口映射） |
| **minikube Pod** | localhost = **Pod 自己** → Connection refused |

W2 正确方向（与 Phase 注释一致）：

```yaml
KAFKA_ADVERTISED_LISTENERS: "PLAINTEXT://kafka:19092,PLAINTEXT_HOST://192.168.19.64:9092"
```

Pod 可用：

- bootstrap：`host.minikube.internal:9092` 或 `192.168.19.64:9092`
- 真正建连：跟 advertised 走 `192.168.19.64:9092`（Pod 已验证能访问该 IP）

### 5.3 consumer group 为啥加 `-k8s` 后缀

Windows IDEA 若还开着本地 consumer，会和集群 consumer 抢同一个 `group-id`，表现为：

- 有时本地吃到消息、集群日志安静  
- 或 rebalance 抖动  

学习环境给集群单独 `device-report-consumer-group-k8s`，对照更干净。

---

## 6. ConfigMap 与「为什么必须 restart」

```text
kubectl apply ConfigMap  →  etcd 里对象已更新
        │
        ✖  正在跑的容器环境变量不会热更新（envFrom 场景）
        │
kubectl rollout restart  →  新 Pod 启动时重新挂载 env
```

例外（W2 不用纠结）：挂载为文件的 ConfigMap + 应用自己 watch 文件，才可能热加载。  
你们现在是 **环境变量注入** → **改完必 restart**。

同 tag 换镜像同理：`imagePullPolicy: IfNotPresent` 时要先 `minikube image rm` 再 `load`，否则节点可能继续用旧层。

---

## 7. 三条 API 各自证明什么（K2）

| API | 证明 |
|-----|------|
| `POST .../reports` | report Pod → PostgreSQL（W1 能力仍在） |
| `POST .../reports-with-dispatch` | report Pod → **Service DNS** → dispatch Pod |
| `POST .../reports-async` | report → Kafka → **consumer Pod** → PostgreSQL |

路径务必带 `deviceId`：

```text
/api/v1/devices/{deviceId}/reports
/api/v1/devices/{deviceId}/reports-with-dispatch
/api/v1/devices/{deviceId}/reports-async
```

（早期 K1 脚本曾误写成 `/api/v1/reports`，W2 计划里已要求修正。）

---

## 8. 排障顺序（建议照着做）

```text
1. kubectl get pods -n iot-learn
   → 是否全 1/1？
2. kubectl get svc -n iot-learn
   → 是否有 command-dispatch-service / device-report-consumer？
3. kubectl describe pod ... / kubectl logs ...
   → ImagePull？CrashLoop？连 DB？连 Kafka localhost？
4. minikube ssh -- nc -zv host.minikube.internal 9092
   → 端口层
5. docker exec kafka-learn ... 看 advertised / 或看应用日志里的 broker 地址
   → 应用层 metadata
6. 从 report Pod wget/curl dispatch Service health
   → DNS + 集群内 HTTP
```

---

## 9. 命令速查

```bash
kubectl get all -n iot-learn
kubectl get cm -n iot-learn
kubectl describe svc command-dispatch-service -n iot-learn

kubectl logs -n iot-learn deploy/device-report-service --tail=100
kubectl logs -n iot-learn deploy/command-dispatch-service --tail=100
kubectl logs -n iot-learn deploy/device-report-consumer --tail=100

kubectl rollout restart deployment/device-report-service -n iot-learn
kubectl port-forward -n iot-learn svc/device-report-service 8765:8765

minikube image load command-dispatch-service:0.1.0-SNAPSHOT
minikube image load device-report-consumer:0.1.0-SNAPSHOT
minikube ssh -- nc -zv 192.168.19.64 9092
```

---

## 10. W2 故意还没碰的东西

| 概念 | 何时 |
|------|------|
| Ingress / 对外域名 | W3 |
| Prometheus 抓 K8s Pod | W3 |
| Helm values 多环境 | W4–W5 |
| Argo CD / Rollouts 金丝雀 | W6–W7 |
| 打开 Nacos discovery 对照 | 选修或后续周 |

---

## 11. 自测题（合上文档回答）

1. 同 Namespace 访问 Service 的短名格式是什么？  
2. Feign 的 `name` 和 `url` 同时存在时，实际连谁？  
3. 为什么修 Kafka 只改客户端 `bootstrap-servers` 往往不够？  
4. 改完 ConfigMap 忘了 restart，会出现什么症状？  
5. K2 三条请求分别验证哪条链路？

答不上来就回到对应小节；能答上来再执行 `2026-07-16-stage2-w2-three-services.md`。
