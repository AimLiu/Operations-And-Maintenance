# Sentinel + Nacos 规则配置说明

## 两处配置分工

| 位置 | 内容 |
|------|------|
| `device-report-service/application.yml` | `spring.cloud.sentinel.datasource.*` — 告诉应用去哪读规则 |
| Nacos 控制台 | **JSON 规则数组** — 规则真实内容 |

## Nacos 配置项

| Data ID | Group | 模板 |
|---------|-------|------|
| `device-report-service-flow-rules` | `SENTINEL_GROUP` | `nacos-flow-rules-device-report.json` |
| `device-report-service-degrade-rules` | `SENTINEL_GROUP` | `device-report-service-degrade-rules.json` |

## Maven 依赖

除 `spring-cloud-starter-alibaba-sentinel` 外，还需：

```xml
<dependency>
    <groupId>com.alibaba.csp</groupId>
    <artifactId>sentinel-datasource-nacos</artifactId>
</dependency>
```

## 场景操作

完整 R1–R6 步骤见：`iot-learn-lab/docs/phase3-scenarios-runbook.md`

## Sentinel Dashboard

```bash
cd iot-learn-lab/infra/sentinel
docker compose -f docker-compose-sentinel-dashboard.yml up -d
```

访问：`http://192.168.19.64:8858`（sentinel/sentinel）
