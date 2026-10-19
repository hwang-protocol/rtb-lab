#!/bin/bash
# 在虚拟机上运行：演示场景，约 5 分钟。配合 Grafana 大盘观看。
#   阶段 1~3：1000 / 3000 / 5000 rps 各 60 秒（正常）
#   阶段 4  ：故障重现——用 systemd drop-in 临时把 HttpServer 空闲连接上限改回 200，再压 5000 rps
#   结束    ：删除 drop-in，恢复正常配置
set -euo pipefail
cd ~/rtb-lab
export LOADGEN_TEXTFILE=/var/lib/node_exporter/textfile/loadgen.prom
URL=http://127.0.0.1:8080/bid
DROPIN_DIR=/etc/systemd/system/rtb-bidder.service.d
DROPIN=$DROPIN_DIR/fault-idle200.conf

load() {  # 参数：速率 秒数
  echo "$(date +%T) ==> $1 rps × $2 秒"
  java -XX:UseSVE=0 -Xmx512m -cp build/loadgen LoadGen "$URL" "$1" "$2" 5 50 2>&1 | grep -E "延迟|超时"
  sleep 10
}

restart_bidder() {
  sudo systemctl daemon-reload
  sudo systemctl restart rtb-bidder
  until curl -sf http://127.0.0.1:8080/health >/dev/null; do sleep 0.5; done
}

cleanup() { sudo rm -f "$DROPIN"; restart_bidder; echo "$(date +%T) ==> 已恢复正常配置"; }
trap cleanup EXIT

load 1000 60
load 3000 60
load 5000 60

echo "$(date +%T) ==> 注入故障：maxIdleConnections=200"
sudo mkdir -p "$DROPIN_DIR"
# 取出当前的 JAVA_OPTS，只把空闲连接上限改成 200
CUR=$(systemctl show rtb-bidder -p Environment --value | grep -o 'JAVA_OPTS=[^"]*-Xlog[^ ]*' || true)
sudo tee "$DROPIN" >/dev/null <<EOF
[Service]
Environment="JAVA_OPTS=-Xms512m -Xmx512m -XX:+UseG1GC -XX:UseSVE=0 -Dsun.net.httpserver.maxIdleConnections=200 -Xlog:gc*:file=/var/log/rtb-bidder/gc.log:time,uptime:filecount=5,filesize=10m"
EOF
restart_bidder
systemctl show rtb-bidder -p Environment --value | grep -o 'maxIdleConnections=[0-9]*'
load 5000 60
