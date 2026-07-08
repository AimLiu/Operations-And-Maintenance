#!/usr/bin/env bash
# 场景 R3：Nacos 规则热更新 — 修改 flow QPS 后无需重启 JVM
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DURATION="${DURATION:-30}"

echo "=== R3 Nacos 规则热更新 ==="
echo ""
echo "本场景分三阶段，请按提示操作 Nacos 控制台："
echo "  Data ID: device-report-service-flow-rules"
echo "  Group: SENTINEL_GROUP"
echo ""
echo "阶段 A — 当前 QPS=5（默认）"
echo "按 Enter 开始压测 ${DURATION}s ..."
read -r _
DURATION="$DURATION" "$SCRIPT_DIR/scenario-r2-sentinel-flow-block.sh" | tee /tmp/r3-phase-a.log

echo ""
echo "阶段 B — 请在 Nacos 将 count 从 5 改为 20，发布配置后按 Enter ..."
read -r _
echo "再次压测 ${DURATION}s ..."
DURATION="$DURATION" "$SCRIPT_DIR/scenario-r2-sentinel-flow-block.sh" | tee /tmp/r3-phase-b.log

echo ""
echo "=== R3 完成 ==="
echo "对比 /tmp/r3-phase-a.log 与 /tmp/r3-phase-b.log 中 201/429 比例："
echo "  阶段 B 的 201 应明显多于阶段 A（阈值放宽，block 减少）"
echo "无需重启 device-report-service。"
