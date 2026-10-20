# rtb-lab：迷你实时竞价平台（Linux 排查与调优实验）

以广告实时竞价（RTB）系统为原型搭建的个人实验项目，用来练习 Linux 服务部署、性能测量、故障排查与调优。
**这是自己搭建的仿真环境，不是任何公司的生产系统。**

## 组成

| 目录 | 内容 |
|---|---|
| `bidder/` | 竞价服务（Java 21，只用 JDK 自带库）。`POST /bid` 竞价，`/health`，`/metrics`（Prometheus 格式） |
| `loadgen/` | 压测程序：开环固定速率发送简化版 OpenRTB 请求，输出 P50/P90/P99/P99.9、超时率 |
| `deploy/` | systemd 服务文件 + 部署脚本（同步代码 → 编译 → 安装为 `rtb-bidder.service`） |
| `results/` | 每次实验 / 排查的记录 |

## 使用

```bash
# 在 Mac 上：部署到虚拟机（默认 ssh 主机名 rocky9）
./deploy/deploy.sh

# 在虚拟机上：压测（每秒 3000 个请求，持续 20 秒）
ssh rocky9
cd ~/rtb-lab
java -XX:UseSVE=0 -cp build/loadgen LoadGen http://127.0.0.1:8080/bid 3000 20

# 查看服务
systemctl status rtb-bidder
journalctl -u rtb-bidder -f
curl -s localhost:8080/metrics
```

## 监控、告警与日志（Prometheus + Alertmanager + Loki + Grafana）

```
rocky9 虚拟机（全部只监听 127.0.0.1，systemd 管理，各自专用系统用户）
 ├── rtb-bidder      :8080/metrics  竞价服务：QPS、出价/不出价、服务端耗时直方图、JVM 堆
 ├── node_exporter   :9100/metrics  机器：CPU、负载、TCP 状态、上下文切换；
 │                                   以及 textfile 采集器读取的 loadgen.prom（客户端延迟）
 ├── Prometheus      :9090          每 5 秒抓取，保留 7 天；按 monitoring/alerts/ 里的规则计算告警
 ├── Alertmanager    :9093          告警分组、去重、抑制、路由
 ├── alert-receiver  :9095          本地告警接收器：把通知写进 journald（实验环境代替 Slack / 邮件）
 ├── Alloy           :12345         日志采集：journald（所有 systemd 服务）+ JVM GC 日志 → Loki
 ├── Loki            :3100          日志存储，只给标签（unit / level / job）建索引，保留 7 天
 └── Grafana         :3000          大盘 "RTB Lab 总览"（自动导入）：告警、指标，最下面一排是日志
```

```bash
./monitoring/deploy-monitoring.sh      # Mac 上：安装 / 更新监控组件
ssh -fN rocky9-mon                     # Mac 上：打开 SSH 隧道（3000 / 9090 / 9093）
open http://localhost:3000             # Grafana：用户 admin，密码见虚拟机上的 ~/.config/rtb-lab/grafana-admin-password
open http://localhost:9090/alerts      # Prometheus：告警规则及其状态（inactive / pending / firing）
open http://localhost:9093             # Alertmanager：当前告警、静默（silence）
ssh rocky9 'bash ~/rtb-lab/monitoring/verify-alerting.sh'   # 端到端验证告警链路（约 7 分钟）
ssh rocky9 'journalctl -u alert-receiver -f'               # 实时看告警通知（机器本地的日志）
# 集中日志：Grafana → Explore → 数据源选 Loki，例如：
#   {unit="rtb-bidder.service"}                        竞价服务的日志
#   {job="systemd-journal", level=~"err|crit"}         所有服务的错误
#   {job="rtb-bidder-gc"} |= "Pause"                   GC 停顿
ssh rocky9 'bash ~/rtb-lab/loadgen/run-scenario.sh'        # 约 5 分钟演示流量，含一次故障重现
ssh rocky9 'bash ~/rtb-lab/loadgen/run-scenario.sh fault'  # 只跑 2 分钟故障，用来测试告警
```

告警规则（`monitoring/alerts/rtb-lab-rules.yml`，阈值依据实测数据）：
BidderDown、BidderClientLatencyHigh（客户端 P99 > 10 ms）、BidderServerLatencyHigh、LoadgenErrors、
BidderFreqTableGrowing、TcpTimeWaitHigh、NodeCpuHigh、NodeMemoryLow、NodeDiskSpaceLow、ExporterDown。
抑制规则：BidderDown 触发时，不再通知它引起的延迟 / 错误类告警。

大盘修改：编辑 `monitoring/grafana/make_dashboard.py` → `python3 make_dashboard.py > rtb-overview.json` → 重新部署监控。

**为什么同时看两种延迟：** 服务端耗时只统计"请求进入业务代码之后"的时间；
排队、建连这些开销只有客户端能看到（排查记录 01 就是这种情况）。

## 目标（SLO）

- P99 延迟 < 10 ms
- 超时率（50 ms）< 0.1%

## 实验记录

| # | 主题 | 结果 |
|---|---|---|
| 01 | [5000 rps 时延迟暴涨：TCP 连接反复重建](results/2026-10-19-01-connection-churn.md) | P50 45.9 ms → 0.25 ms，P99 60 ms → 5.6 ms |
| 02 | [告警链路端到端验证](results/2026-10-19-02-alerting-verification.md) | 触发 / 恢复 / 静默 / 抑制全部生效 |

## 计划

完整任务清单和进度见 [TASKS.md](TASKS.md)。
