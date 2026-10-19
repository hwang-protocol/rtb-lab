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

## 目标（SLO）

- P99 延迟 < 10 ms
- 超时率（50 ms）< 0.1%

## 实验记录

| # | 主题 | 结果 |
|---|---|---|
| 01 | [5000 rps 时延迟暴涨：TCP 连接反复重建](results/2026-10-19-01-connection-churn.md) | P50 45.9 ms → 0.25 ms，P99 60 ms → 5.6 ms |

## 计划

- [ ] 压测程序移到独立机器，消除同机抢 CPU 的干扰
- [ ] 接入 Redis（预算 / 频次），练习连接池与网络排查
- [ ] Prometheus + Grafana 监控
- [ ] 故障注入：fd 上限、内存泄漏与 OOM、网卡软中断、吵闹邻居、磁盘写满、DNS 慢
- [ ] Terraform + Ansible 部署到 EC2
