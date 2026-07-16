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

echo "WSL_TO_WINDOWS_IP=$WSL_TO_WINDOWS_IP"
echo "WSL_FROM_WINDOWS_IP=$WSL_FROM_WINDOWS_IP"
echo "POD_MIDDLEWARE_HOST=$POD_MIDDLEWARE_HOST"
echo "K8S_NAMESPACE=$K8S_NAMESPACE"