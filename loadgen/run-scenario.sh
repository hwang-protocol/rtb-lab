#!/bin/bash
# 在虚拟机上运行：演示场景，约 5 分钟。配合 Grafana 大盘观看。
# 用法：bash run-scenario.sh        完整演示
#       bash run-scenario.sh fault  只跑故障阶段 2 分钟（测试告警用）
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
  local out
  if ! out=$(java -XX:UseSVE=0 -Xmx512m -cp build/loadgen LoadGen "$URL" "$1" "$2" 5 50 2>&1) \
     || ! grep -q "延迟" <<<"$out"; then
    # 压测程序没有正常跑完：把完整输出打出来并退出，不要"静悄悄地"跳过（曾因此导致告警验证失效）
    echo "❌ 压测程序运行失败，完整输出："; echo "$out"; exit 1
  fi
  grep -E "延迟|超时" <<<"$out"
  sleep 10
}

# 开始前检查：压测程序是否已编译（部署脚本的 rsync 曾误删 build/ 目录）
[ -f build/loadgen/LoadGen.class ] || { echo "❌ 找不到 build/loadgen/LoadGen.class，请先在 Mac 上运行：cd ansible && ansible-playbook site.yml"; exit 1; }

restart_bidder() {
  sudo systemctl daemon-reload
  sudo systemctl restart rtb-bidder
  until curl -sf http://127.0.0.1:8080/health >/dev/null; do sleep 0.5; done
}

cleanup() { sudo rm -f "$DROPIN"; restart_bidder; echo "$(date +%T) ==> 已恢复正常配置"; }
trap cleanup EXIT

MODE="${1:-full}"           # full：完整演示；fault：只跑故障阶段（用来测试告警）
FAULT_SECONDS=60
if [ "$MODE" = "fault" ]; then
  FAULT_SECONDS=120          # 跑久一点，保证告警的 for 时长能满足
else
  load 1000 60
  load 3000 60
  load 5000 60
fi

echo "$(date +%T) ==> 注入故障：maxIdleConnections=200"
sudo mkdir -p "$DROPIN_DIR"
sudo tee "$DROPIN" >/dev/null <<EOF
[Service]
Environment="JAVA_OPTS=-Xms512m -Xmx512m -XX:+UseG1GC -XX:UseSVE=0 -Dsun.net.httpserver.maxIdleConnections=200 -Xlog:gc*:file=/var/log/rtb-bidder/gc.log:time,uptime:filecount=5,filesize=10m"
EOF
restart_bidder
systemctl show rtb-bidder -p Environment --value | grep -o 'maxIdleConnections=[0-9]*'
load 5000 "$FAULT_SECONDS"
