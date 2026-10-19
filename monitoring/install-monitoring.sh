#!/bin/bash
# 在虚拟机上运行（由 monitoring/deploy-monitoring.sh 从 Mac 远程调用）：
# 安装 Prometheus + node_exporter + Grafana，全部作为 systemd 服务，只监听 127.0.0.1。
set -euo pipefail
cd "$(dirname "$0")"

PROM_VER=3.15.0
NODE_VER=1.12.1
AM_VER=0.34.1
ARCH=linux-arm64            # Apple 芯片虚拟机是 ARM；在 x86 的 EC2 上改成 linux-amd64
# Grafana 管理员密码：不写在代码里。优先用环境变量；否则读取 / 首次随机生成，保存在只有本人可读的文件中
PW_FILE="$HOME/.config/rtb-lab/grafana-admin-password"
if [ -z "${GRAFANA_ADMIN_PASSWORD:-}" ]; then
  if [ ! -s "$PW_FILE" ]; then
    mkdir -p "$(dirname "$PW_FILE")"
    (umask 077; openssl rand -base64 18 > "$PW_FILE")
    echo "==> 已生成 Grafana 管理员密码，保存在 $PW_FILE"
  fi
  GRAFANA_ADMIN_PASSWORD=$(cat "$PW_FILE")
fi

install_prom_binary() {     # 参数：项目名 版本 要安装的可执行文件...
  local name=$1 ver=$2; shift 2
  local tgz="$name-$ver.$ARCH.tar.gz"
  local url="https://github.com/prometheus/$name/releases/download/v$ver"
  local work; work=$(mktemp -d)
  echo "==> 下载 $tgz"
  curl -sSL --fail -o "$work/$tgz" "$url/$tgz"
  curl -sSL --fail -o "$work/sha256sums.txt" "$url/sha256sums.txt"
  echo "==> 校验 SHA256"
  (cd "$work" && grep " $tgz\$" sha256sums.txt | sha256sum -c -)
  tar -xzf "$work/$tgz" -C "$work"
  for bin in "$@"; do
    sudo install -m 0755 "$work/$name-$ver.$ARCH/$bin" /usr/local/bin/"$bin"
  done
  rm -rf "$work"
}

add_system_user() {
  id "$1" >/dev/null 2>&1 || sudo useradd --system --no-create-home --shell /sbin/nologin "$1"
}

# ---------- Prometheus ----------
if ! /usr/local/bin/prometheus --version 2>/dev/null | grep -q "version $PROM_VER"; then
  install_prom_binary prometheus "$PROM_VER" prometheus promtool
fi
add_system_user prometheus
sudo mkdir -p /etc/prometheus/rules /var/lib/prometheus
sudo cp prometheus.yml /etc/prometheus/prometheus.yml
sudo rm -f /etc/prometheus/rules/*.yml
sudo cp alerts/*.yml /etc/prometheus/rules/
sudo chown -R prometheus:prometheus /var/lib/prometheus
echo "==> 检查 Prometheus 配置和告警规则语法"
/usr/local/bin/promtool check config /etc/prometheus/prometheus.yml

# ---------- Alertmanager ----------
if ! /usr/local/bin/alertmanager --version 2>&1 | grep -q "version $AM_VER"; then
  install_prom_binary alertmanager "$AM_VER" alertmanager amtool
fi
add_system_user alertmanager
sudo mkdir -p /etc/alertmanager /var/lib/alertmanager
sudo cp alertmanager.yml /etc/alertmanager/alertmanager.yml
sudo chown -R alertmanager:alertmanager /var/lib/alertmanager
echo "==> 检查 Alertmanager 配置语法"
/usr/local/bin/amtool check-config /etc/alertmanager/alertmanager.yml

# ---------- 本地告警接收器（Alertmanager webhook → journald）----------
add_system_user alertrx
sudo mkdir -p /opt/alert-receiver
sudo install -m 0644 alert-receiver/receiver.py /opt/alert-receiver/receiver.py
sudo restorecon -R /etc/alertmanager /var/lib/alertmanager /opt/alert-receiver 2>/dev/null || true
sudo cp systemd/alertmanager.service systemd/alert-receiver.service /etc/systemd/system/

# ---------- node_exporter ----------
if ! /usr/local/bin/node_exporter --version 2>&1 | grep -q "version $NODE_VER"; then
  install_prom_binary node_exporter "$NODE_VER" node_exporter
fi
add_system_user node_exporter
# textfile 目录：压测程序（用户 lab）往里写 loadgen.prom，node_exporter 读取
sudo mkdir -p /var/lib/node_exporter/textfile
sudo chown "$USER":node_exporter /var/lib/node_exporter/textfile
sudo chmod 0755 /var/lib/node_exporter/textfile

sudo restorecon -R /usr/local/bin /etc/prometheus /var/lib/prometheus /var/lib/node_exporter 2>/dev/null || true
sudo cp systemd/prometheus.service systemd/node_exporter.service /etc/systemd/system/

# ---------- Grafana（官方 RPM 软件源，dnf 会校验 GPG 签名）----------
if ! rpm -q grafana >/dev/null 2>&1; then
  echo "==> 添加 Grafana 软件源并安装"
  sudo tee /etc/yum.repos.d/grafana.repo >/dev/null <<'EOF'
[grafana]
name=grafana
baseurl=https://rpm.grafana.com
repo_gpgcheck=1
enabled=1
gpgcheck=1
gpgkey=https://rpm.grafana.com/gpg.key
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
EOF
  sudo dnf install -y -q grafana
fi
# Grafana 的 systemd 服务会读取 /etc/sysconfig/grafana-server 里的环境变量
sudo sed -i '/^GF_/d' /etc/sysconfig/grafana-server
sudo tee -a /etc/sysconfig/grafana-server >/dev/null <<EOF
GF_SERVER_HTTP_ADDR=127.0.0.1
GF_SECURITY_ADMIN_PASSWORD=$GRAFANA_ADMIN_PASSWORD
GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH=/var/lib/grafana/dashboards/rtb-overview.json
GF_ANALYTICS_REPORTING_ENABLED=false
GF_ANALYTICS_CHECK_FOR_UPDATES=false
EOF
sudo cp grafana/datasource.yml /etc/grafana/provisioning/datasources/rtb-lab.yml
sudo cp grafana/dashboards.yml /etc/grafana/provisioning/dashboards/rtb-lab.yml
sudo mkdir -p /var/lib/grafana/dashboards
sudo cp grafana/rtb-overview.json /var/lib/grafana/dashboards/
sudo chown -R grafana:grafana /var/lib/grafana/dashboards

# ---------- 启动 ----------
sudo systemctl daemon-reload
SERVICES="node_exporter alert-receiver alertmanager prometheus grafana-server"
sudo systemctl enable --now $SERVICES
sudo systemctl restart $SERVICES

echo "==> 等待服务就绪"
for i in $(seq 1 60); do
  curl -sf http://127.0.0.1:9090/-/ready >/dev/null && curl -sf http://127.0.0.1:9093/-/ready >/dev/null \
    && curl -sf http://127.0.0.1:3000/api/health >/dev/null && break
  sleep 1
done
for s in $SERVICES; do printf "  %-16s %s\n" "$s" "$(systemctl is-active "$s")"; done
echo "==> Prometheus 抓取目标状态："
curl -s http://127.0.0.1:9090/api/v1/targets | python3 -c 'import json,sys;[print("  ",t["labels"]["job"],t["health"],t.get("lastError","")) for t in json.load(sys.stdin)["data"]["activeTargets"]]'
