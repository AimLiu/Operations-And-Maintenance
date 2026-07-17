# Stage 2 W3 前置知识：Ingress、NodePort 与外部 Prometheus

**读者：** 已完成 W2（三服务 + Feign/Kafka），能用 Service DNS 和 port-forward，但还没做过集群 HTTP 入口与「集群外监控抓集群内指标」  
**范围：** 只覆盖 Stage 2 W3（Ingress + NodePort + 外部 Prometheus scrape）会碰到的概念  
**对照计划：** `docs/superpowers/plans/2026-07-16-stage2-w3-ingress-prometheus.md`  
**不讲：** Helm、Argo、Prometheus Operator / ServiceMonitor、APISIX 改 upstream（W4+）

读完你应能回答六件事：

1. Ingress 和 Service 各管哪一层，请求怎么从浏览器进到 Pod  
2. 为什么学习环境用 `Host` 头访问，而不必一上来就配 `/etc/hosts`  
3. 外部 Prometheus 为什么要 NodePort（而不是继续 `kubectl port-forward`）  
4. `kubectl apply` 改 Service 后为何立刻生效——是不是「动态热加载本地 YAML」？  
5. Docker 里的 Prometheus 为什么经常 ping 不通 `minikube ip`，怎么接网  
6. K3 脚本里「IDEA vs Ingress」延迟对照在证明什么  

---

## 1. 先看一串你马上要敲的命令

```bash
minikube addons enable ingress

# Service → NodePort（给 Ingress 后端 + Prometheus）
kubectl apply -f iot-learn-lab/infra/k8s/device-report/service.yaml
kubectl apply -f iot-learn-lab/infra/k8s/command-dispatch/service.yaml

# Ingress
kubectl apply -f iot-learn-lab/infra/k8s/device-report/ingress.yaml

# Host 头访问（把 IP 换成 minikube ip）
curl -H "Host: device-report.iot-learn.local" http://$(minikube ip)/actuator/health

# 验证脚本
iot-learn-lab/scripts/stage2/scenario-k3-ingress-baseline.sh
```

成功时大致会看到：

```text
ingress.networking.k8s.io/device-report-ingress created
...
{"status":"UP"...}
...
K3 PASS: Ingress + NodePort metrics 路径打通
```

下面所有概念，都是在解释：**流量怎么从集群外拐进 Pod，以及指标怎么被集群外的 Prometheus 拿走。**

---

## 2. 和 W1 / W2 / Phase 1 对比

| 以前 | W3 |
|------|-----|
| `kubectl port-forward` 临时开本地端口 | **Ingress** 按 Host 提供较稳定的 HTTP 入口 |
| Service 只有 ClusterIP（集群内） | 改为 **NodePort**：集群外也能用 `节点IP:端口` |
| Prometheus 抓 Windows IDEA `192.168.16.1:8765` | 额外抓 minikube `$(minikube ip):30765` |
| Phase 1 只关心「应用有没有指标」 | W3 关心「**混合架构**下监控如何够到 K8s」 |

W3 仍然不把 Prometheus 搬进集群；这是 Spec 定的混合策略，也为以后对比 ServiceMonitor 留空间。

---

## 3. Service vs Ingress：别混成一个东西

### 3.1 分工

| 对象 | 层 | 干什么 |
|------|----|--------|
| **Service** | 偏 L4（TCP/UDP 转发到 Pod） | 给一组 Pod 一个稳定虚拟入口（DNS / ClusterIP / NodePort） |
| **Ingress** | **L7 HTTP(S)** | 按 **Host / Path**（还可 TLS）把请求转到某个 Service |

口诀：

> **Service 找 Pod；Ingress 找 Service。**  
> Ingress 不能代替 Service——YAML 里 backend 必须写已有 Service。

### 3.2 一跳请求长什么样

```text
curl -H "Host: device-report.iot-learn.local" http://192.168.49.2/
        │
        ▼
minikube 节点 :80  →  ingress-nginx-controller Pod
        │  看 Host / Path 规则
        ▼
Service device-report-service:8765
        │  selector → Endpoints
        ▼
device-report Pod:8765
```

没有正确的 `Host` 时，nginx 常常直接 **404**——不是业务挂了，是 **没匹配到任何 rule**。

### 3.3 `ingressClassName: nginx`

集群里可以有多套 Ingress Controller。`ingressClassName: nginx` 表示：

> 「这份 Ingress 交给名字叫 nginx 的 Controller 处理。」

minikube `addons enable ingress` 装的就是 nginx 系控制器。确认：

```bash
kubectl get ingressclass
```

---

## 4. 两种访问 Ingress 的方式

### 4.1 Host 头（W3 推荐主路径）

```bash
curl -H "Host: device-report.iot-learn.local" http://$(minikube ip)/actuator/health
```

- **不改** `/etc/hosts`
- **不依赖** 前台挂着的 `minikube tunnel`
- HTTP 语义与「真域名访问」一致（Host 就是虚拟主机名）

### 4.2 tunnel + 域名（加分项）

```bash
minikube tunnel
# 再把 device-report.iot-learn.local 指到 127.0.0.1 或文档指定地址
curl http://device-report.iot-learn.local/actuator/health
```

更接近生产「浏览器打开域名」；但 tunnel 要权限、要占一个终端，学习排障时 Host 头更稳。

---

## 5. NodePort：给「集群外」开的门

### 5.1 ClusterIP 为什么不够

| 客户端位置 | ClusterIP `10.x.x.x:8765` |
|------------|---------------------------|
| 同集群 Pod | ✅ |
| WSL 宿主机 / Docker 容器 | ❌ 默认路由不到 |

Prometheus 在 **WSL Docker**，属于集群外 → 需要 NodePort、LoadBalancer、或 port-forward 之一。

### 5.2 NodePort 在干什么

```text
任意节点 IP :30765  →  Service  →  Ready Pod:8765
```

W3 固定：

| 服务 | nodePort |
|------|----------|
| device-report | 30765 |
| command-dispatch | 30767 |

面试一句：

> 「NodePort 把 Service 暴露在节点 IP 的固定端口上；Ingress 走 80/443 做七层路由，NodePort 更适合监控这种『直连端口 scrape』。」

### 5.3 为什么不天天 port-forward 给 Prometheus？

| port-forward | NodePort |
|--------------|----------|
| 进程挂了就断 | 随 Service 一直在 |
| 每人/每会话要重开 | scrape 配置写一次（IP 变了再改） |
| 适合调试 | 适合「常驻监控」学习 |

### 5.4 `kubectl apply` 之后 Service 为何立刻变成 NodePort？

Task 2 里常见疑惑：刚执行完

```bash
kubectl apply -f iot-learn-lab/infra/k8s/device-report/service.yaml
kubectl get svc -n iot-learn
```

`TYPE` 马上从 `ClusterIP` 变成 `NodePort`，端口也出现 `8765:30765/TCP`——**这是不是集群在「动态热加载」本地 YAML？**

**不是。** 集群不会监视你磁盘上的文件；是 **`apply` 把声明推到了 API Server**，对象一更新，转发规则跟着变。

```text
你改本地 service.yaml（type: NodePort）
        │
        ✖  只改文件、不 apply → 集群完全不变
        │
        ▼
kubectl apply  →  API Server 更新 etcd 里的 Service 对象
        │
        ▼
kube-proxy（各节点）watch 到变化 → 立刻重写 iptables/ipvs 等转发规则
        │
        ▼
kubectl get svc 立刻看到 TYPE=NodePort
```

和 ConfigMap 对比（W2 已踩过）：

| 对象 | apply 之后 | 业务 Pod 要不要 restart？ |
|------|------------|---------------------------|
| **Service**（改 type / port / selector） | kube-proxy 马上改转发 | **一般不用**（Service 与容器进程解耦） |
| **ConfigMap → envFrom** | etcd 里已是新值 | **要** `rollout restart`（已运行容器的环境变量不会热更新） |

其它容易误会的点：

| 现象 | 含义 |
|------|------|
| `AGE` 仍是 `2d` / `6h` | AGE 是 **对象创建时间**，`apply` 更新字段不会把 AGE 清零 |
| 只 apply 了 `device-report`，但 `command-dispatch` 也已是 NodePort | 说明 **那份 yaml 也已经 apply 过**；一次 apply 不会「连带」改别的 Service |
| `device-report-consumer` 仍是 ClusterIP | 计划没改它 → 保持原样，说明改动是 **按清单文件逐个声明** 的 |

自检「集群里到底是什么」：

```bash
kubectl get svc device-report-service -n iot-learn -o yaml | grep -E 'type:|nodePort:'
```

口诀：

> **YAML 是说明书；`kubectl apply` 才是提交。Service 提交后即时生效，不必重启 Pod。**

---

## 6. 外部 Prometheus 的两道坎

### 6.1 配置坎：static_configs

Phase 1 已有抓 IDEA 的 job。W3 **追加** job，例如：

```yaml
- job_name: device-report-service-k8s
  metrics_path: /actuator/prometheus
  static_configs:
    - targets: ['192.168.49.2:30765']
```

注意：`192.168.49.2` 必须换成你的 `minikube ip`。删集群重建后 IP 常变 → targets 会集体 DOWN。

### 6.2 网络坎：容器够不着 minikube 网段

```text
prometheus-learn（docker bridge）
        ✖  默认到不了 192.168.49.2
minikube 节点（docker 网络 "minikube"）
```

常用修法：

```bash
docker network connect minikube prometheus-learn
```

让 Prometheus 多挂一块「能看见 minikube IP」的网卡。然后再：

```bash
docker exec prometheus-learn wget -qO- http://$(minikube ip):30765/actuator/prometheus | head
```

口诀：

> **配置对了但 target DOWN，先怀疑网络命名空间，再怀疑路径或鉴权。**

### 6.3 为什么 W3 不上 ServiceMonitor？

ServiceMonitor 属于 **Prometheus Operator** 体系：集群内 Prometheus 通过 CRD 发现抓取目标。  
本阶段 Prometheus 故意留在 Docker → **static_configs + NodePort** 更贴合混合架构，也更少新组件。Spec 把 ServiceMonitor 放到更后的选修周。

---

## 7. 延迟对照在证明什么

K3 脚本对 `GET /actuator/health` 做多次采样，比较：

| 路径 | 多出来的东西（相对 IDEA 进程内） |
|------|----------------------------------|
| IDEA `192.168.16.1:8765` | WSL→Windows 一跳（若从 WSL 测） |
| NodePort `minikube_ip:30765` | 节点端口转发 → kube-proxy → Pod |
| Ingress + Host | **再加** nginx Ingress 代理一跳 |

你要记住的不是「必须慢多少毫秒」，而是：

> **每多一个代理层，就多一份延迟与故障面；金丝雀 / 网关实验前先有基线数字。**

IDEA 没开时脚本会 `SKIP` 直连，只比 Ingress vs NodePort——仍然有价值。

---

## 8. 排障顺序（建议照着做）

```text
1. kubectl get pods -n ingress-nginx
   → controller 是否 1/1？
2. kubectl get ingress,svc -n iot-learn
   → ADDRESS？NodePort 30765/30767？
3. curl minikube_ip:30765/actuator/health
   → NodePort 层通不通？
4. curl -H "Host: ..." http://minikube_ip/actuator/health
   → Ingress 规则通不通？（对比第 3 步）
5. docker network inspect minikube | head
   → Prometheus 是否已 connect？
6. Prometheus UI /targets
   → DOWN 看 last error（connection refused vs timeout）
```

---

## 9. 命令速查

```bash
minikube addons list | grep ingress
minikube ip
kubectl get ingressclass
kubectl get ingress -n iot-learn -o wide
kubectl describe ingress device-report-ingress -n iot-learn

curl -H "Host: device-report.iot-learn.local" http://$(minikube ip)/actuator/health
curl http://$(minikube ip):30765/actuator/prometheus | head

docker network connect minikube prometheus-learn
curl -X POST http://127.0.0.1:9090/-/reload

iot-learn-lab/scripts/stage2/scenario-k3-ingress-baseline.sh
```

---

## 10. W3 故意还没碰的东西

| 概念 | 何时 |
|------|------|
| Helm values 管 Ingress/host | W4–W5 |
| APISIX upstream → NodePort/Ingress | W4–W7 |
| Argo CD / Rollouts 金丝雀 | W6–W7 |
| Jaeger 全链路 | W8 |
| ServiceMonitor / PodMonitor | 选修周 |

---

## 11. 自测题（合上文档回答）

1. Ingress 的 backend 写 Pod IP 可以吗？为什么？  
2. 不带 `Host` 头访问 `http://$(minikube ip)/` 常见什么现象？  
3. ClusterIP、NodePort、Ingress 三个里，谁最适合给 Docker 里的 Prometheus 用？  
4. 只改本地 `service.yaml` 不 `apply`，`kubectl get svc` 会变吗？apply 后为什么通常不用重启 Pod？  
5. `docker network connect minikube prometheus-learn` 解决的是配置问题还是网络问题？  
6. 延迟对照里 Ingress 通常比 NodePort 多哪一跳？

答不上来就回到对应小节；能答上来再执行 `2026-07-16-stage2-w3-ingress-prometheus.md`。
