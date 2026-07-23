# Jaeger all-in-one（Stage 2 W8）

混合可观测：业务在 minikube，**Jaeger 留在 WSL Docker**（与 Prometheus 同类）。

## 版本与资源选型

| 项 | 选择 | 原因 |
|----|------|------|
| 镜像 | `jaegertracing/all-in-one:1.76.0` | 1.x 末代稳定线；仍支持环境变量 + Badger；不必上 Jaeger 2.x 配置文件 |
| 形态 | all-in-one 单容器 | Collector + Query + UI 一体，最省内存 |
| 存储 | Badger → `./data` | 重启不丢 lab 数据；无需 Elasticsearch |
| TTL | `BADGER_SPAN_STORE_TTL=72h` | 控制磁盘 |
| 网络 | 专用 `iot-learn-jaeger` | Pod 经宿主机端口访问，无需并入其它 compose 网 |
| 限额 | CPU 0.5 / 内存 512M | 适合学习机与小服务器 |

## 启动 / 停止

在 WSL 自行创建目录并放入本文件后：

```bash
cd /path/to/jaeger   # 含 docker-compose*.yml 的目录
mkdir -p data
sudo chown -R 10001:10001 ./data   # 镜像以 UID 10001 写 Badger，必须先授权
docker compose -f docker-compose.yml up -d   # 或 docker-compose-jaeger.yml
docker compose ps
docker compose down   # 停容器；data/ 保留
```

## 端口

| 端口 | 用途 |
|------|------|
| `16686` | UI / Query API |
| `4318` | OTLP HTTP（应用优先） |
| `4317` | OTLP gRPC |
| `14269` | Admin / healthcheck |

## 访问地址

| 谁 | 地址 |
|----|------|
| 浏览器 UI | `http://127.0.0.1:16686` 或 `http://<WSL-IP>:16686` |
| minikube Pod 推送 | `http://host.minikube.internal:4318/v1/traces` |
| IDEA 本机 | `http://127.0.0.1:4318/v1/traces` |

## 自检

```bash
# UI
curl -sf http://127.0.0.1:16686/ | head -c 200

# 健康（admin）
curl -sf http://127.0.0.1:14269/

# Pod 视角 OTLP 端口（404/405 也算「端口通」）
kubectl -n iot-learn run curl-otlp --rm -it --image=curlimages/curl --restart=Never -- \
  curl -sS -m 3 -o /dev/null -w "%{http_code}\n" http://host.minikube.internal:4318/
```

## 与 Prometheus 对照

| | Prometheus | Jaeger |
|--|------------|--------|
| 部署 | WSL Docker | WSL Docker（本目录） |
| 模型 | 拉 `/actuator/prometheus` | 应用推 OTLP |
| Pod 找宿主机 | NodePort / scrape IP | `host.minikube.internal:4318` |

## 排障

| 现象 | 处理 |
|------|------|
| UI 打不开 | `docker ps` / `docker logs jaeger-learn`；端口是否被占 |
| Pod → 4318 超时 | Jaeger 是否 healthy；`host.minikube.internal` 是否通 |
| 重启后无旧 trace | 确认 `./data` 已挂载且 `BADGER_EPHEMERAL=false` |
| 磁盘涨 / permission denied | 调小 TTL；或 `sudo chown -R 10001:10001 ./data` 后重启 |
