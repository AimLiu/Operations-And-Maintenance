#!/usr/bin/env bash
set -euo pipefail
WF="${WF:-iot-learn-lab-ci.yml}"
echo "== K9: GitHub Actions CI =="
command -v gh >/dev/null || { echo "K9 FAIL: gh CLI required (or document manual check)"; exit 1; }
JSON=$(gh run list --workflow="$WF" --limit 1 --json conclusion,status,displayTitle,url)
echo "$JSON" | head -c 500
echo
echo "$JSON" | grep -q '"conclusion":"success"' || { echo "K9 FAIL: latest run not success"; exit 1; }
echo "K9 PASS: latest ${WF} run success"
echo "Verify GHCR tags manually if needed."