# 记录 #02：告警链路端到端验证

- 日期：2026-10-19
- 环境：UTM 虚拟机 Rocky 9.8 aarch64，4 vCPU / 4 GB（个人实验环境，非生产）
- 版本：Prometheus 3.15.0 · Alertmanager 0.34.1 · node_exporter 1.12.1
- 脚本：[`monitoring/verify-alerting.sh`](../monitoring/verify-alerting.sh)（约 7 分钟，可重复运行）

## 要证明什么

"Alertmanager 装好了"不等于"告警能用"。告警链路有四层，每层都可能断：

```
规则（Prometheus 判断异常）→ 发送（Prometheus → Alertmanager）→ 处理（分组 / 静默 / 抑制）→ 送达（webhook 接收器）
```

所以验证要覆盖：配置合法、链路连通、空闲不误报、真实故障能触发、通知能送达、故障恢复后有恢复通知、静默和抑制都生效。

## 结果

| 步骤 | 做法 | 预期 | 实际 |
|---|---|---|---|
| ① 配置检查 | `promtool check config`、`amtool check-config` | SUCCESS | ✅ 10 条规则，两份配置都 SUCCESS |
| ② 链路连通 | 查 `/api/v1/rules`、`/api/v1/alertmanagers` | 规则已加载，Alertmanager 已连接 | ✅ 10 条规则；已连接 `127.0.0.1:9093` |
| ③ 空闲无误报 | 无负载时查告警 | 无告警 | ✅ 无 |
| ④ 故障触发 | 用 drop-in 把 maxIdleConnections 改回 200，压 5000 rps × 120 s（重现 [#01](2026-10-19-01-connection-churn.md)） | 延迟、TIME_WAIT 告警触发并发出通知 | ✅ 开始 39 s 后 BidderClientLatencyHigh、TcpTimeWaitHigh 触发；客户端 P99 70 ms |
| ④ 恢复通知 | 故障结束后等待 | 收到恢复通知 | ✅ 12:27:19 / 12:27:24 收到恢复通知 |
| ⑥ 静默 | 先用 `amtool silence add` 静默 TcpTimeWaitHigh | 触发但不通知 | ✅ 状态为 `suppressed`（被静默），接收器全程没收到它的通知 |
| ⑤ 抑制 | 停掉 rtb-bidder，同时继续压测 | BidderDown 通知；连带的 LoadgenErrors 被抑制 | ✅ LoadgenErrors 状态为 `suppressed`（被 BidderDown 抑制），没有发通知 |

## 证据：接收器收到的全部通知（journald）

```
12:25:19 [🔥 触发] critical BidderClientLatencyHigh  客户端 P99 延迟 76.8 ms，超过 SLO 10 ms
12:25:24 [🔥 触发] critical LoadgenErrors            客户端每秒 75.0 个请求失败（超时 / 连接错误）
12:27:19 [✅ 恢复] critical BidderClientLatencyHigh
12:27:24 [✅ 恢复] critical LoadgenErrors
12:28:49 [🔥 触发] critical BidderDown               竞价服务无法抓取（进程挂了或 /metrics 不可用）
12:29:49 [✅ 恢复] critical BidderDown
```

这份时间线里**没出现**的两条告警，同样是证据：

- TcpTimeWaitHigh：在 Prometheus 里是 firing，但被静默，所以没有通知。
- ⑤ 阶段的 LoadgenErrors：被 BidderDown 抑制，所以没有通知。值班的人只收到"服务挂了"一条，不会被连带告警刷屏。

## 过程中发现的问题

第一次跑验证时，④ 一直等不到告警。原因：

1. `deploy-monitoring.sh` 用 `rsync --delete` 同步代码，把虚拟机上 `deploy.sh` 编译好的 `build/` 目录删了，压测程序 `LoadGen` 不存在。
2. `run-scenario.sh` 把压测输出通过 `grep` 过滤，java 报 `ClassNotFoundException` 也被吞掉，脚本"静悄悄地"退出，看起来像"告警没触发"。

修复：

- 两个部署脚本的 rsync 都加上 `--exclude build/`。
- `run-scenario.sh` 压测失败时打印完整输出并 `exit 1`。
- 两个脚本开始前都检查 `build/loadgen/LoadGen.class` 是否存在。

教训：验证"告警不响"之前，先确认故障本身真的发生了。没有流量，也就没有告警。

## 复现

```bash
bash deploy/deploy.sh && bash monitoring/deploy-monitoring.sh
ssh rocky9 'bash ~/rtb-lab/monitoring/verify-alerting.sh'
```
