# iot-learn-lab

IoT 运维学习实验的多模块 Maven 父工程。

## 模块

| 模块 | 说明 |
|------|------|
| `device-report-service` | Phase 1 设备上报实验服务（Spring Boot） |

## 环境要求

- Java **21**
- Maven 3.6+
- PostgreSQL 16（本地 `postgres-alpine` 容器，运行时）

## 构建

```bash
# 在 iot-learn-lab 目录下
mvn clean verify
```

## 运行 device-report-service

```bash
mvn spring-boot:run -pl device-report-service
```

## 目录结构

```
iot-learn-lab/
├── pom.xml                         # 父 POM（packaging=pom）
├── device-report-service/          # 子模块
│   └── src/main/java/.../
│       ├── DeviceReportApplication.java
│       ├── controller/             # 待实现
│       ├── service/                # 待实现
│       ├── repository/             # 待实现
│       ├── entity/                 # 待实现
│       └── dto/                    # 待实现
├── infra/                          # Prometheus/Grafana/PostgreSQL 配置（Phase 1 后续任务）
└── scripts/                        # 学习场景压测脚本（Phase 1 后续任务）
```
