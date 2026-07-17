#!/usr/bin/env bash
set -euo pipefail

# WSL → Windows（Phase 1–5：APISIX upstream 指 Windows IDEA 应用）
export WSL_TO_WINDOWS_IP="${WSL_TO_WINDOWS_IP:-$(ip -4 route show default | awk '{print $3}')}"

# Windows → WSL Docker（Windows 浏览器 / IDEA 访问 WSL 中间件）
export WSL_FROM_WINDOWS_IP="${WSL_FROM_WINDOWS_IP:-192.168.19.64}"

# Pod → WSL Docker 中间件（minikube docker driver 首选）
export POD_MIDDLEWARE_HOST="${POD_MIDDLEWARE_HOST:-host.minikube.internal}"

export K8S_NAMESPACE="${K8S_NAMESPACE:-iot-learn}"
export IMAGE_DEVICE_REPORT="${IMAGE_DEVICE_REPORT:-device-report-service:0.1.0-SNAPSHOT}"
export IMAGE_COMMAND_DISPATCH="${IMAGE_COMMAND_DISPATCH:-command-dispatch-service:0.1.0-SNAPSHOT}"
export IMAGE_DEVICE_REPORT_CONSUMER="${IMAGE_DEVICE_REPORT_CONSUMER:-device-report-consumer:0.1.0-SNAPSHOT}"
export INGRESS_HOST="${INGRESS_HOST:-device-report.iot-learn.local}"
export REPORT_NODE_PORT="${REPORT_NODE_PORT:-30765}"
export DISPATCH_NODE_PORT="${DISPATCH_NODE_PORT:-30767}"
# 动态取；minikube 未启动时允许为空
export MINIKUBE_IP="${MINIKUBE_IP:-$(minikube ip 2>/dev/null || true)}"

echo "WSL_TO_WINDOWS_IP=$WSL_TO_WINDOWS_IP"
echo "WSL_FROM_WINDOWS_IP=$WSL_FROM_WINDOWS_IP"
echo "POD_MIDDLEWARE_HOST=$POD_MIDDLEWARE_HOST"
echo "K8S_NAMESPACE=$K8S_NAMESPACE"
echo "INGRESS_HOST=$INGRESS_HOST"
echo "MINIKUBE_IP=$MINIKUBE_IP"
echo "REPORT_NODE_PORT=$REPORT_NODE_PORT"
echo "DISPATCH_NODE_PORT=$DISPATCH_NODE_PORT"