#!/usr/bin/env bash
# 只生成部署配置，不自动安装、部署或启动服务。
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/lib/configure-common.sh" k8s "$@"
