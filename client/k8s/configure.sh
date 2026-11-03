#!/usr/bin/env bash
# 本目录固定部署侧和方式，只读取变量生成配置。
set -euo pipefail
CONFIG_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$CONFIG_DIR/../.." && pwd)"
exec bash "$ROOT/lib/configure-common.sh" client k8s "$CONFIG_DIR" "$@"
