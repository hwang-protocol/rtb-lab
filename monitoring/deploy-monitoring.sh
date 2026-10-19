#!/bin/bash
# 在 Mac 上运行：同步项目到虚拟机，并在虚拟机上安装 / 更新监控组件。
# 用法：./monitoring/deploy-monitoring.sh [ssh主机名，默认 rocky9]
set -euo pipefail
HOST="${1:-rocky9}"
cd "$(dirname "$0")/.."
rsync -az --delete --exclude .git ./ "$HOST":rtb-lab/
ssh "$HOST" 'bash ~/rtb-lab/monitoring/install-monitoring.sh'
