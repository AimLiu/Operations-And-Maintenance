# Stage 2 K8s 实验环境

## 架构：混合中间件

- **进 minikube：** Java 微服务（本目录 manifest）
- **留 WSL Docker：** PostgreSQL、Redis、Kafka、Nacos、Prometheus、Grafana、APISIX

## 启动 minikube

```bash
minikube start --driver=docker --cpus=4 --memory=6144
minikube addons enable metrics-server
```

## 网络：Pod → WSL Docker

| 用途 | 推荐值 |
|------|--------|
| DB / Redis / Sentinel | `host.minikube.internal` |
| Nacos（gRPC 友好） | `192.168.19.64:8848`（WSL eth0；需服务端正确宣告，见下文） |
| ❌ 不要用 | `192.168.16.1`（WSL→Windows 网关） |

部署前自检：

```bash
# WSL：中间件在不在
nc -zv localhost 5432
nc -zv localhost 8848
nc -zv localhost 9848

# Pod 视角（minikube 节点）
minikube ssh -- nc -zv host.minikube.internal 5432
minikube ssh -- nc -zv host.minikube.internal 8848
minikube ssh -- nc -zv host.minikube.internal 9848
minikube ssh -- nc -zv 192.168.19.64 8848
```

端口通了 ≠ Nacos 客户端一定正常，见下一节。

## 踩坑实录：Nacos 端口通，但日志狂报 `127.0.0.1:9848`

### 现象

- `minikube ssh -- nc -zv host.minikube.internal 8848/9848` → **succeeded**
- Pod 仍 `1/1 Running`，业务可通
- `kubectl logs` 反复出现：

```text
grpc client connection server:127.0.0.1 ip,serverPort:9848
Server check fail ... 127.0.0.1 ,port 9848
Fail to connect server ... serverIp = '127.0.0.1', server main port = 8848
*_config-0 ... Client not connected, current status:STARTING
ConfigBatchListenRequest ...
```

### 原因（两层）

```text
① 客户端初始 server-addr
   = host.minikube.internal:8848 或 192.168.19.64:8848
        │
        ▼ HTTP/注册相关交互可能先摸到 Nacos
        │
② Nacos 把「自己的成员地址」回给客户端 = 127.0.0.1
        │
        ▼
③ 客户端改连 Pod 内的 127.0.0.1:9848（gRPC = 主端口 + 1000）
        │
        ▼ Connection refused（Nacos 不在 Pod 里）
```

**为什么服务端会宣告 127.0.0.1？**

- Docker 单机 Nacos 默认按容器内网卡探测，常落成 loopback。
- 只设 `NACOS_SERVER_IP` → 脚本只加 `-Dnacos.server.ip=...`（主要影响控制台展示 URL），**不等于** gRPC 成员地址用的 `nacos.inetutils.ip-address`。
- 若把 `-Dnacos.inetutils.ip-address=...` 写在 **`JAVA_OPT_EXT`**：官方 `docker-startup.sh` 会把它拼在 **`-jar` 之后**，变成 Spring Boot 程序参数，**进不了 JVM**，宣告仍然是 `127.0.0.1`。

**为什么日志里是 `*_config-0`？**

- `application.yml` 里若有 `spring.config.import: optional:nacos:...`，会**强制**拉起 Nacos **配置**客户端（线程名常带 `_config-0`）。
- 仅写 `spring.cloud.nacos.config.enabled=false` **挡不住** 这个 import。
- Phase 4 的 `device-report-v2-app.yaml` 导入应只放在 `application-v2.yml`；默认 / `k8s` profile 不应强依赖。

### 正确改法

**Nacos docker-compose（服务端）：**

```yaml
environment:
  MODE: "standalone"
  PREFER_HOST_MODE: "ip"
  NACOS_SERVER_IP: "192.168.19.64"
  # 必须用 JAVA_OPT（拼在 -jar 前）；不要用 JAVA_OPT_EXT 传 -D
  JAVA_OPT: "-Dnacos.inetutils.ip-address=192.168.19.64"
```

```bash
docker compose up -d --force-recreate nacos
# -D 必须出现在 -jar 前面：
docker exec nacos-standalone cat /proc/1/cmdline | tr '\0' ' '
```

**应用侧（W1 已落地）：**

| 项 | 做法 |
|----|------|
| `application.yml` | 去掉默认的 `optional:nacos` import |
| `application-v2.yml` | 保留 Phase 4 配置导入 |
| `application-k8s.yml` | W1：`discovery/config enabled: false`（K1 不依赖注册中心） |
| ConfigMap `NACOS_ADDR` | `192.168.19.64:8848` |

改 yml 后：**rebuild → `minikube image rm` → `image load` → 重新 apply Deployment**。同 tag 覆盖时务必先删节点旧镜像。

改 Nacos 后：**必须 `kubectl rollout restart` 业务 Pod**；旧进程会缓存错误服务端地址（可能重试成千上万次）。

### 和「端口映射」的关系

```text
0.0.0.0:8848->8848、0.0.0.0:9848-9849->9848-9849
```

映射正确只保证「从宿主机/网关 IP 能连上 Nacos」。  
客户端按 **错误宣告地址** 去连时，仍然会失败——这是应用层地址协商问题，不是再开一个端口能解决的。

## 常用命令

```bash
kubectl get pods -n iot-learn
kubectl logs -n iot-learn deploy/device-report-service -f
kubectl port-forward -n iot-learn svc/device-report-service 8765:8765
minikube image load device-report-service:0.1.0-SNAPSHOT

# 同 tag 换新镜像时推荐：
kubectl delete deployment device-report-service -n iot-learn
minikube image rm device-report-service:0.1.0-SNAPSHOT
minikube image load device-report-service:0.1.0-SNAPSHOT
kubectl apply -f device-report/deployment.yaml
```

## 概念讲解

前置知识长文：`docs/superpowers/guides/2026-07-14-stage2-w1-k8s-primer.md`
