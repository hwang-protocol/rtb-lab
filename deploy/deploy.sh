#!/bin/bash
# 在 Mac 上运行：把代码同步到虚拟机，编译，并以 systemd 服务的方式（重新）部署竞价服务。
# 用法：./deploy/deploy.sh [ssh主机名，默认 rocky9]
set -euo pipefail
HOST="${1:-rocky9}"
cd "$(dirname "$0")/.."

echo "==> 同步代码到 $HOST:~/rtb-lab"
rsync -az --delete --exclude .git --exclude build/ ./ "$HOST":rtb-lab/

ssh "$HOST" 'bash -s' <<'REMOTE'
set -euo pipefail
cd ~/rtb-lab

echo "==> 编译"
rm -rf build && mkdir -p build/bidder build/loadgen
javac -d build/bidder bidder/src/*.java
javac -d build/loadgen loadgen/src/*.java

echo "==> 创建服务专用用户、目录"
id rtb >/dev/null 2>&1 || sudo useradd --system --no-create-home --shell /sbin/nologin rtb
sudo mkdir -p /opt/rtb-bidder /var/log/rtb-bidder
sudo rm -rf /opt/rtb-bidder/classes
sudo cp -r build/bidder /opt/rtb-bidder/classes
sudo chown -R rtb:rtb /opt/rtb-bidder /var/log/rtb-bidder

echo "==> 安装并重启 systemd 服务"
sudo cp deploy/rtb-bidder.service /etc/systemd/system/rtb-bidder.service
sudo systemctl daemon-reload
sudo systemctl enable rtb-bidder >/dev/null 2>&1
sudo systemctl restart rtb-bidder

for i in $(seq 1 30); do
  if curl -sf http://127.0.0.1:8080/health >/dev/null; then echo "==> 服务已就绪"; break; fi
  sleep 0.5
done
systemctl --no-pager --lines=3 status rtb-bidder
REMOTE
