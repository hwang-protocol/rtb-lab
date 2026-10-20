#!/bin/bash
# 在虚拟机上运行：端到端验证告警链路，约 8 分钟。
#   ① 配置检查  ② 链路连通  ③ 空闲无误报
#   ④ 故障重现（连接反复重建）→ 告警触发 → 通知送达 → 恢复通知
#   ⑤ 抑制：竞价服务挂掉时，连带的请求失败告警被抑制
#   ⑥ 静默：人工静默 TcpTimeWaitHigh 后，它不再发通知
# 用法：bash ~/rtb-lab/monitoring/verify-alerting.sh
set -uo pipefail
cd ~/rtb-lab
PROM=http://127.0.0.1:9090
AM=http://127.0.0.1:9093
AMTOOL="/usr/local/bin/amtool --alertmanager.url=$AM"
T0=$(date '+%Y-%m-%d %H:%M:%S')
ts() { date +%T; }
step() { echo; echo "======== $(ts) $* ========"; }

# 开始前检查：压测程序必须已编译，否则 ④⑤ 会因为没有流量而"假失败"
[ -f build/loadgen/LoadGen.class ] || { echo "❌ 找不到 build/loadgen/LoadGen.class，请先在 Mac 上运行：cd ansible && ansible-playbook site.yml"; exit 1; }

prom_alerts() {   # 打印 Prometheus 里当前的告警及状态（pending / firing）
  curl -s $PROM/api/v1/alerts | python3 -c '
import json,sys
a=json.load(sys.stdin)["data"]["alerts"]
print("   （无）" if not a else "\n".join("   %-26s %s" % (x["labels"]["alertname"], x["state"]) for x in a))'
}

am_alerts() {     # 打印 Alertmanager 里的告警及其状态（active / suppressed）和原因
  curl -s "$AM/api/v2/alerts?active=true&silenced=true&inhibited=true" | python3 -c '
import json,sys
a=json.load(sys.stdin)
if not a: print("   （无）")
for x in a:
    st=x["status"]; why=""
    if st["inhibitedBy"]: why="被抑制，原因："+",".join(st["inhibitedBy"])
    if st["silencedBy"]:  why="被静默，静默 ID："+",".join(s[:8] for s in st["silencedBy"])
    print("   %-26s %-10s %s" % (x["labels"]["alertname"], st["state"], why))'
}

wait_for_alert() {   # 等某条告警在 Prometheus 里进入 firing，最多等 $2 秒
  local name=$1 max=$2
  for _ in $(seq 1 "$max"); do
    curl -s $PROM/api/v1/alerts | grep -q "\"alertname\":\"$name\".*\"state\":\"firing\"" && { echo "   $(ts) $name → firing"; return 0; }
    sleep 1
  done
  echo "   ⚠️ $name 在 $max 秒内没有触发"; return 1
}

# ---------- ① 配置检查 ----------
step "① 配置检查"
/usr/local/bin/promtool check config /etc/prometheus/prometheus.yml | grep -E "SUCCESS|FAILED"
/usr/local/bin/amtool check-config /etc/alertmanager/alertmanager.yml | grep -E "SUCCESS|FAILED"

# ---------- ② 链路连通 ----------
step "② 链路连通"
echo "   Prometheus 加载的告警规则数：$(curl -s $PROM/api/v1/rules | python3 -c 'import json,sys;print(sum(len(g["rules"]) for g in json.load(sys.stdin)["data"]["groups"]))')"
echo "   Prometheus 连接的 Alertmanager：$(curl -s $PROM/api/v1/alertmanagers | python3 -c 'import json,sys;print([a["url"] for a in json.load(sys.stdin)["data"]["activeAlertmanagers"]])')"
for s in prometheus alertmanager alert-receiver node_exporter rtb-bidder; do printf "   %-15s %s\n" "$s" "$(systemctl is-active $s)"; done

# ---------- ③ 空闲无误报 ----------
step "③ 空闲时的告警（应该为空）"
rm -f /var/lib/node_exporter/textfile/loadgen.prom
prom_alerts

# ---------- ⑥ 静默（先设置，在 ④ 里验证）----------
step "⑥ 设置静默：TcpTimeWaitHigh 静默 15 分钟"
SID=$($AMTOOL silence add alertname=TcpTimeWaitHigh --duration=15m --author=verify-alerting --comment="验证静默功能")
echo "   静默 ID：$SID"

# ---------- ④ 故障重现 ----------
step "④ 故障重现：maxIdleConnections=200 + 5000 rps × 120 秒（后台运行）"
bash loadgen/run-scenario.sh fault > /tmp/verify-fault.log 2>&1 &
FAULT_PID=$!
wait_for_alert BidderClientLatencyHigh 100
wait_for_alert TcpTimeWaitHigh 30
sleep 15
echo "   -- Prometheus 中的告警："; prom_alerts
echo "   -- Alertmanager 中的告警（TcpTimeWaitHigh 应为被静默）："; am_alerts
wait $FAULT_PID
grep -E "延迟|超时" /tmp/verify-fault.log | sed 's/^/   压测结果：/'
step "④ 故障已恢复，等待告警恢复（约 90 秒）"
sleep 90
prom_alerts

# ---------- ⑤ 抑制 ----------
step "⑤ 抑制：停掉竞价服务，同时持续压测（请求会全部失败）"
sudo systemctl stop rtb-bidder
LOADGEN_TEXTFILE=/var/lib/node_exporter/textfile/loadgen.prom \
  java -XX:UseSVE=0 -Xmx256m -cp build/loadgen LoadGen http://127.0.0.1:8080/bid 200 75 0 50 > /tmp/verify-inhibit.log 2>&1 &
LG_PID=$!
wait_for_alert BidderDown 60
wait_for_alert LoadgenErrors 70
sleep 10
echo "   -- Alertmanager 中的告警（LoadgenErrors 应为被抑制）："; am_alerts
wait $LG_PID
sudo systemctl start rtb-bidder
until curl -sf http://127.0.0.1:8080/health >/dev/null; do sleep 0.5; done
echo "   $(ts) rtb-bidder 已恢复"

step "收尾：删除静默，等待恢复通知（约 80 秒）"
$AMTOOL silence expire "$SID" && echo "   静默已删除"
sleep 80
prom_alerts

# ---------- 通知时间线 ----------
step "告警接收器收到的全部通知（这就是"通知送达"的证据）"
journalctl -u alert-receiver --since "$T0" -o short-iso --no-pager \
  | grep -E "触发|恢复" | sed -E 's/^[0-9-]+T([0-9:]+)[^ ]* [^ ]+ [^:]+: /   \1 /' | cut -c1-110
echo; echo "验证完成。"
