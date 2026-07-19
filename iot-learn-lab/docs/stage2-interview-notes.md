# Stage 2 面试复盘笔记

**日期：** 2026-07-13 起  
**架构：** 混合中间件（Java 微服务进 minikube + PostgreSQL / Redis / Kafka / Nacos 留 WSL Docker）

> 操作步骤见：W1–W4 plans + `docs/superpowers/plans/2026-07-19-stage2-w5-helm-values.md`（W5）  
> 概念导读：W1–W4 guides + `docs/superpowers/guides/2026-07-19-stage2-w5-helm-values.md`  
> 踩坑详解：`iot-learn-lab/infra/k8s/README.md` · Helm 速查：`docs/stage2-helm-cheatsheet.md`（W5 产出）

---

## W1 场景记录

| 场景 | 日期 | 通过？ | 关键现象 |
|------|------|--------|----------|
| K1 K8s 基线 | 2026-07-14 | ☑ | minikube Ready；Pod Running；Windows `localhost:8765` port-forward health UP；`/app/log` 与 Nacos `127.0.0.1:9848` 已踩坑并文档化 |

## W2 场景记录

| 场景 | 日期 | 通过？ | 关键现象 |
|------|------|--------|----------|
| K2 三服务互通 | | ☐ | Feign 同步 201；async 202；consumer 落库；`scenario-k2-three-services.sh` → K2 PASS |

## W3 场景记录

| 场景 | 日期 | 通过？ | 关键现象 |
|------|------|--------|----------|
| K3 Ingress + Prom | 2026-07-17 | ☑ | Host 头 health UP；Ingress sync POST 成功；NodePort 可 scrape；`*-k8s` targets UP（需 `docker network connect minikube`）；`scenario-k3-ingress-baseline.sh` → K3 PASS |

---

## W1 面试题自测（摘要）

| 问题 | 面试一句 |
|------|----------|
| Pod vs Deployment？ | Pod 是最小调度单位（常含 pause + 业务容器）；Deployment 通过 ReplicaSet 管副本数与滚动更新，Pod 挂了会建新 Pod |
| liveness vs readiness？ | readiness 失败摘流量不重启；liveness 失败达阈值重启容器 |
| Pod 连 WSL PostgreSQL？ | ConfigMap 注入 `host.minikube.internal:5432`；Spring 读 env 建 JDBC；网络由 minikube→WSL Docker 映射提供 |
| 多阶段 Dockerfile？ | 构建阶段 JDK+Maven，运行阶段只留 JRE+JAR，镜像更小、攻击面更小 |
| `IfNotPresent`？ | 优先用 **节点**（minikube）已有镜像；WSL build 后须 `minikube image load`；同 tag 覆盖须先停 Pod 再 rm/load |

---

## W2 面试题自测

### 1. 同 Namespace 下访问 Service，DNS 短名怎么写？FQDN 呢？

**我的初答（摘要）：**

- 同 ns 用 `http://appName+端口`；跨 ns 用 `namespace.appName+端口`；FQDN 不清楚。

**精炼结论（面试版）：**

解析的是 **Service 的 `metadata.name`**，不是 Deployment 名或 Pod 名（W2 里常故意同名）。

| 场景 | 写法 | W2 示例 |
|------|------|---------|
| 同 Namespace **短名** | `http://<service名>:<port>` | `http://command-dispatch-service:8767` |
| 跨 Namespace | `http://<service>.<namespace>:<port>` | `http://foo.other-ns:8080` |
| **FQDN**（完全限定域名） | `<service>.<namespace>.svc.cluster.local:<port>` | `command-dispatch-service.iot-learn.svc.cluster.local:8767` |

**FQDN 四段含义：**

```text
command-dispatch-service  .  iot-learn  .  svc  .  cluster.local
        Service 名              Namespace    固定段    集群 DNS 域
```

同 Namespace 下短名与 FQDN 解析到同一 ClusterIP；FQDN 写全了在任何 Namespace 都不会歧义。

**面试一句：** 同 ns 用 Service 短名 `:port`；跨 ns 加 `.<namespace>`；最完整是 `.<namespace>.svc.cluster.local`。

---

### 2. 为什么 W2 不用 Nacos 做 Feign 发现，而用 `DISPATCH_BASE_URL`？

**我的初答（摘要）：**

- 服务没注册 Nacos，没法用 Nacos 路由；`DISPATCH_BASE_URL` 用来测同 ns 服务连通性。

**精炼结论（面试版）：**

现象对，还要补 **设计动机**：

| Nacos 发现（Phase 1–5） | K8s Service DNS（W2） |
|------------------------|------------------------|
| 适合 Windows + WSL 混合、进程不在 K8s | 适合 **Pod 都在同一集群** |
| 依赖注册中心、gRPC、服务端 IP 宣告 | CoreDNS + Service **集群内原生、稳定** |
| W1 k8s profile 已 **关闭** discovery/config | Feign 用 `DISPATCH_BASE_URL=http://command-dispatch-service:8767` |

W2 故意用固定 URL，是为了：

1. 验证 **同 Namespace Service DNS**（K2 核心）
2. 避开混合部署里 Nacos `127.0.0.1:9848` 类问题
3. 把「注册中心发现」和「集群内寻址」分开学（W6+ 再对比 Argo / Nacos）

**面试一句：** W2 三服务都在 K8s 内，Service DNS 更简单可靠；Nacos 留给 Phase 对比和集群外中间件，Feign 用 `DISPATCH_BASE_URL` 指向 `command-dispatch-service:8767`。

---

### 3. Kafka「bootstrap 能连、业务仍失败」通常卡在哪一步？

**我的初答（摘要）：**

- bootstrap 能连，但 advertised 返回 `localhost:9092`，Pod 里 localhost 是自己，连不上 WSL Kafka。

**精炼结论（面试版）：**

与 Nacos `127.0.0.1:9848` **同一类问题**——broker **metadata 里宣告的地址**不对。

```text
Pod → bootstrap（如 host.minikube.internal:9092）  TCP 可能通
     → Broker 返回 advertised.listeners = localhost:9092
     → Pod 改连 localhost:9092 → 连到 Pod 自己 → 生产/消费失败
```

排查重点：

- `docker-compose` / `KAFKA_ADVERTISED_LISTENERS` 必须是 **Pod 可达地址**（如 `PLAINTEXT://192.168.19.64:9092`）
- **不能**是 `localhost:9092`（Broker 容器内视角）
- `nc` bootstrap 端口通 **≠** 客户端一定能用

**面试一句：** bootstrap 只是第一次握手；真正生产/消费还看 **advertised.listeners**，Pod 里 localhost 必挂。

---

### 4. ConfigMap 改了环境变量，为什么还要 `rollout restart`？

**我的初答（摘要）：**

- 只有 rollout restart 后 Pod 才会用新环境变量重新启动。

**精炼结论（面试版）：**

**完全正确。**

ConfigMap 经 `envFrom` 注入时，环境变量在 **Pod 创建时** 写入容器进程；**运行中的 Pod 不会自动 reload**。

```bash
kubectl apply -f configmap-env.yaml      # 只更新集群里的 ConfigMap 对象
kubectl rollout restart deployment/...   # 重建 Pod，新 Pod 才读到新 env
```

若 Deployment 已被删掉（如 Task 3 同 tag 覆盖时 `delete deployment`），应 **`kubectl apply -f deployment.yaml`** 重建，而不是 `rollout restart`（会 NotFound）。

**面试一句：** env 在容器启动时注入；改 ConfigMap 不重启 Pod，旧进程仍用旧 env。

---

### 5. consumer 为何单独设 `KAFKA_CONSUMER_GROUP_ID=...-k8s`？

**我的初答（摘要）：**

- 防止和 Windows 上的 consumer 重复，导致冲突。

**精炼结论（面试版）：**

**正确。** 同一 `group.id` 时，Kafka 会把 topic 分区在 **所有 group 成员之间 rebalance**：

- Windows IDEA 上的 consumer 与 K8s Pod consumer **抢分区、抢 offset**
- 表现为：async 202 但 PG 无数据、或消息被另一套 consumer 吃掉，难排查

加 `-k8s` 后缀 = **独立消费组**，W2 实验与本地 consumer **并行不干扰**。

**面试一句：** 避免与 Windows 本地 consumer 共用 group，防止 rebalance 和 offset 互相抢。

---

## W2 踩坑记录

| 踩坑 | 原因 | 处理 |
|------|------|------|
| `minikube image rm` 报 container is using image | 运行中 Pod 占用镜像 layer | `kubectl scale/delete deployment` → 再 `image rm` → `load` → `apply deployment` |
| `rollout restart` NotFound | Task 3 删了 Deployment 未重建 | `kubectl apply -f deployment.yaml`，不是 restart |
| Feign 走 fallback | `DISPATCH_BASE_URL` 错或未建 Service | 查 ConfigMap；`kubectl get svc -n iot-learn` |
| consumer 连 `localhost:9092` | Kafka advertised 未改 | Task 1 改 `192.168.19.64:9092` + restart consumer |
| ConfigMap 改了 Feign 仍 localhost | 未滚动 Pod | `rollout restart` 或 delete Pod |
| async 202 但 PG 无数据 | group 与 Windows 冲突 / consumer 未 Ready | 独立 `...-k8s` group；看 consumer 日志 |

## W1 踩坑记录（归档）

| 踩坑 | 原因 | 处理 |
|------|------|------|
| `/app/log` CrashLoop | 非 root 写不了日志目录 | Dockerfile 预建 `/app/log` + chown |
| Nacos `127.0.0.1:9848` | 服务端宣告 loopback；`JAVA_OPT_EXT` 的 `-D` 在 `-jar` 后无效 | `JAVA_OPT=-Dnacos.inetutils.ip-address=...`；W1 关 discovery/config |
| 同 tag 镜像不更新 | minikube 节点仍用旧 layer | 停 Pod → `image rm` → `load` → 重建 Deployment |
| Windows `192.168.19.64:8765` 不通 | port-forward 默认只绑 `127.0.0.1` | Windows 用 `localhost:8765` 或 `--address 0.0.0.0` |

---

## W2 面试话术速记（一页纸）

| 问题 | 答法 |
|------|------|
| Service DNS？ | 同 ns：`http://svc名:port`；FQDN：`svc.ns.svc.cluster.local:port` |
| Feign 为何写死 URL？ | W2 集群内用 K8s DNS；避开 Nacos gRPC/宣告；验证 K2 互通 |
| Kafka advertised？ | bootstrap 只是入口；metadata 地址必须 Pod 可达，不能 localhost |
| ConfigMap 为何要 restart？ | env 启动时注入，运行中 Pod 不自动 reload |
| consumer group `-k8s`？ | 与 Windows 本地 consumer 隔离，避免 rebalance/offset 冲突 |
| 与 Phase 3 关系？ | 同一套 Feign/熔断；发现从 localhost/Nacos 换成集群 Service DNS |

---

## W3 面试题自测

### 1. Ingress 和 Service 分别解决什么问题？谁做 L4、谁做 L7？

**我的初答（摘要）：**

- Ingress：外部访问 minikube 内服务时，经 Ingress 组件按规则转发；可选 nginx 等实现；规则里可配 NodePort 等方式。
- Service：解决集群内服务互通，把 Service 名写入配置，用 `http://service-name.namespace.local...:port/url` 访问。

**精炼结论（面试版）：**

初答方向对，三处要拧正：

| 初答 | 纠正 |
|------|------|
| Ingress 规则是 NodePort | NodePort 是 **Service 类型**；Ingress 规则是 **Host / Path**（还可 TLS） |
| Service 只做服务间互通 | 还做 Ingress **backend**、以及 NodePort 给集群外（如 Prometheus） |
| `service.namespace.local` | FQDN 是 `<svc>.<ns>.svc.cluster.local`；同 ns 短名 `http://svc:port` |

| 对象 | 层 | 干什么 |
|------|----|--------|
| **Service** | 偏 **L4** | 稳定入口 → 一组 Pod（DNS / ClusterIP / NodePort） |
| **Ingress** | **L7 HTTP(S)** | 按 Host/Path 转到某个 Service |

口诀：**Service 找 Pod；Ingress 找 Service。Ingress 不能代替 Service。**

**面试一句：** Service 偏四层找 Pod；Ingress 七层按域名/路径找 Service。

---

### 2. 为什么 W3 用 NodePort 给 Prometheus，而不是继续 port-forward？

**我的初答（摘要）：**

- NodePort 固定、配好后稳定；port-forward 适合本地临时调试，不适合正式常驻；宕机后会断（并自觉可能和 tunnel 弄混）。

**精炼结论（面试版）：**

「常驻 vs 临时」正确；和 **tunnel** 要分开：

| | port-forward | minikube tunnel | NodePort |
|--|--------------|-----------------|----------|
| 用途 | 本机临时调试 | 本机访问 LB/Ingress（常占 80） | 集群外固定端口 scrape |
| 权限 | 一般不需要管理员 | 常要（80/443） | 不需要 |
| 何时断 | `kubectl` 进程结束 | tunnel 进程结束 | Service 在就一直在 |

W3 选 NodePort：外部 Prometheus 要 **长期、可配置的 scrape 地址**（`$(minikube ip):30765`），不能依赖前台挂着的 port-forward。

**面试一句：** 监控要常驻 scrape 用 NodePort；port-forward 给人调试，别和 tunnel 混。

---

### 3. 从 Docker 里的 Prometheus 访问 `minikube ip` 失败时，你怎么排？

**我的初答（摘要）：**

- 先查 Pod / Ingress；WSL 能通则从 Prometheus 容器内测；不通则两容器不同网桥，用 `docker connect` 互通。

**精炼结论（面试版）：**

容器内探测 + 接网 **正确**；**查 Ingress 对 Prometheus 几乎无用**（抓的是 NodePort，不走 Host 规则）。

推荐顺序：

```text
1. 宿主机：curl http://$(minikube ip):30765/actuator/prometheus
2. 配置：prometheus.yml 是否含 192.168.49.2:30765 / 30767
3. 容器内：docker exec prometheus-learn wget ... 同地址
4. 不通 → docker network connect minikube prometheus-learn
5. UI /targets → device-report-service-k8s / command-dispatch-service-k8s UP
```

**面试一句：** 宿主机通、容器不通 → 网络命名空间问题；`docker network connect minikube prometheus-learn`，与 Ingress 无关。

---

### 4. `ingressClassName: nginx` 和 minikube addon 是什么关系？

**我的初答（摘要）：**

- `ingressClassName: nginx` 表示用 nginx 做 Ingress 路由；addon 表示是否启用 Ingress 层；类似 SLF4J 与具体日志实现。

**精炼结论（面试版）：**

类比成立，更贴一点：

| 概念 | 作用 |
|------|------|
| `minikube addons enable ingress` | **安装** ingress-nginx 控制器，并提供名为 `nginx` 的 IngressClass |
| `ingressClassName: nginx` | 这份 Ingress **交给** 该 Class/控制器处理 |

没 enable → 没有实现；写了 Class 但控制器不在 → 规则不生效。

**面试一句：** addon 装 nginx 实现；`ingressClassName` 选定这份规则由谁处理。

---

### 5. IDEA 直连通常比 Ingress 快还是慢？慢在哪几跳？

**我的初答（摘要）：**

- IDEA 直连 Prometheus 应比 Ingress 快，因为 Ingress 还要在集群里找服务。

**精炼结论（面试版）：**

题意是访问 **同一业务**（如 `/actuator/health`），不是「IDEA 连 Prometheus」：

| 路径 | 相对快慢 | 多出来的跳 |
|------|----------|------------|
| IDEA `:8765` 直连 | 通常最快 | — |
| NodePort `:30765` | 中间 | kube-proxy → Pod |
| Ingress + Host | 通常最慢 | **再加** nginx Ingress **L7 代理** |

慢主要在 **多一跳 ingress-nginx**，不是笼统的「找服务慢」。

**面试一句：** IDEA 直连通常更快；Ingress 多 nginx 一跳，K3 用来建延迟基线。

---

## W3 踩坑记录

| 踩坑 | 原因 | 处理 |
|------|------|------|
| Prometheus `*-k8s` target DOWN，配置已有 `192.168.49.2` | Prometheus 只在 compose 网，够不着 minikube 网段 | `docker network connect minikube prometheus-learn` |
| 只 curl `http://$(minikube ip)/` 404 | 未带 Host，匹配不到 Ingress rule | `-H "Host: device-report.iot-learn.local"` |
| 以为 Ingress 通了 Prometheus 就该 UP | 抓取走 NodePort，不走 Ingress | 查 `:30765` / 容器网络 |
| 容器重建后 targets 又红 | `network connect` 非持久（未写进 compose） | 重建后再 connect 一次 |

---

## W3 面试话术速记（一页纸）

| 问题 | 答法 |
|------|------|
| Ingress vs Service？ | Service 偏 L4 找 Pod；Ingress L7 按 Host/Path 找 Service |
| 为何 NodePort 给 Prom？ | 常驻固定 scrape；port-forward 会话级；别和 tunnel 混 |
| Prom 访问 minikube IP 失败？ | 宿主机通、容器不通 → `docker network connect minikube` |
| ingressClassName 与 addon？ | addon 装控制器；Class 名选定实现 |
| IDEA vs Ingress 延迟？ | IDEA 通常更快；Ingress 多 nginx 一跳 |
| `kubectl apply` Service？ | 提交后即时生效，一般不必重启 Pod（≠ ConfigMap env） |

---

## 待补

- [ ] K2 场景通过截图 / `scenario-k2-three-services.sh` 输出粘贴
- [ ] K3 延迟数字粘贴（`ingress_host_header_avg_s` / `nodeport_avg_s` / 可选 `idea_direct_avg_s`）
- [ ] Grafana 面板是否区分 `env=learn-k8s`（选修）
- [ ] W4：执行 Helm Chart 计划后补场景表与面试题精炼结论
- [ ] W5：执行 Values/checksum/canary 计划后补场景表与 Helm vs Kustomize 精炼结论
