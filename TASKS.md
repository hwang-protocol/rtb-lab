# rtb-lab 任务清单

> 这是整个项目唯一的任务清单。每做完一步就在这里打勾，并写上日期和提交号。
> 最后更新：2026-10-20

状态说明：✅ 完成 · 🟡 进行中 · ⬜ 未开始 · 💤 以后再说

---

## 当前状态一览

| 阶段 | 内容 | 状态 |
|---|---|---|
| 0 | 基础：虚拟机、竞价服务、压测、监控、告警、日志 | 🟡 日志部分还没提交 |
| 1 | 故障实验（OOM、fd、磁盘） | ⬜ |
| 2 | Ansible：把部署脚本改成 playbook（在 UTM 虚拟机上练，免费） | 🟡 已跑通，未提交 |
| 3 | Terraform：部署到真实的 AWS EC2 | ⬜ |
| 4 | 进阶：Redis、Docker 对比、绑核、Slack 告警 | 💤 |

---

## 阶段 0：基础（已基本完成）

- [x] UTM 虚拟机 Rocky 9（4 核 4 GB），SSH 免密登录 `ssh rocky9`（2026-10-19）
- [x] 竞价服务 Bidder（Java 21，systemd 管理）+ 开环压测程序 LoadGen（`55b9347`）
- [x] 排查记录 #01：5000 rps 时 TCP 连接反复重建，P99 60 ms → 5.6 ms（`a4e63c8`）
- [x] Prometheus + node_exporter + Grafana 大盘（`39aecb5`）
- [x] Alertmanager + 10 条告警规则 + 本地告警接收器（`920d97e`）
- [x] 验证记录 #02：告警触发 / 恢复 / 静默 / 抑制全部验证通过（`920d97e`）
- [x] 修复：部署脚本误删 `build/`、压测失败被吞掉（`920d97e`）
- [x] 发布到 GitHub：github.com/hwang-protocol/rtb-lab（公开）
- [ ] 🟡 **Loki + Alloy 集中日志**：已部署到虚拟机并验证可用，**代码还没提交**
  - 文件：`monitoring/loki/`、`monitoring/alloy/`、Grafana 数据源和日志面板、Prometheus 抓取、ExporterDown 规则、README
  - 同批改动：大盘无数据时显示说明文字（"✅ 没有告警"等）
  - 下一步：你在 VS Code 里看完 → 我在本地提交 → **你说推才推**
- [ ] 🟡 讨论稿 `docs/why-chain-oom-and-fd.md`（OOM 和 fd 的"一直问为什么"），未提交
- [x] 流程图网页（私有链接，需要时在 Share 菜单里分享）：https://claude.ai/artifact/99pYCpwdwiuVeftBjr9jsq

---

## 阶段 1：故障实验（免费，在 UTM 虚拟机上做）

每个实验都要写一份排查记录（`results/`，格式同 #01）：现象 → 定位 → 根因 → 修复 → 前后数据对比。

- [ ] **#03 内存泄漏 → OOM**（书第 13 章 cgroup 内存）
  - [ ] 实验 A：只有 `-Xmx`，观察 `OutOfMemoryError` 和"进程假活着"
  - [ ] 实验 B：加 `MemoryMax` 且故意小于实际需要，观察内核 OOM killer、`memory.events`、systemd `oom-kill`
  - [ ] 修复：频次表加过期；`-XX:+ExitOnOutOfMemoryError`；合理的 `MemoryMax`；堆使用率告警
- [ ] **#04 fd 耗尽**
  - [ ] 实验 A：`LimitNOFILE=256`，看"上限太低"的曲线
  - [ ] 实验 B：加一个故障开关制造 fd 泄漏，看"一直涨不回落"的曲线
  - [ ] 加指标和告警：进程 fd 使用率 > 80%
- [ ] **#05 磁盘写满 + LVM 在线扩容**（磁盘目前只有 10G，正好练）
  - [ ] `du` / `lsof | grep deleted` 定位；logrotate；`lvextend` + `xfs_growfs`

---

## 阶段 2：Ansible（免费，先在 UTM 虚拟机上练）

目标：用 playbook 替换 `deploy/deploy.sh` 和 `monitoring/install-monitoring.sh`，同一份 playbook 以后直接用在 EC2 上。

- [x] Mac 上安装 Ansible：uv + Python 3.12 + ansible-core 2.21.4，扩展 ansible.posix 2.2.2（2026-10-20）
- [x] 清单文件 `ansible/inventory/hosts.yml`：先只有 rocky9 一台，按 bidder / loadgen / monitoring 分组
- [x] 角色拆分：`base`、`rtb_code`、`bidder`、`prom_binary`（通用下载）、`node_exporter`、`alertmanager`、`prometheus`、`loki`、`alloy`、`grafana`
- [x] 版本号统一放在 `group_vars/all.yml`；CPU 架构自动识别（arm64 / amd64），上 EC2 不用改
- [x] 配置先检查再替换（`validate`）；Prometheus 改规则只 reload 不重启（服务文件加了 `ExecReload`）
- [x] 验证幂等：第一次 `changed=18`（从 bash 版迁移），第二次 `changed=0`；修了 rsync 目录时间导致的假变化
- [x] 重跑 `verify-alerting.sh`：触发 / 恢复 / 静默 / 抑制全部通过，和 bash 版结果一致
- [ ] 🟡 提交（等你看完）
- [ ] 旧的 bash 脚本保留一段时间，确认没问题后删除

---

## 阶段 3：Terraform + AWS EC2（花钱，每次用完必须销毁）

### 3.0 开始之前（安全和费用，必须先做）

- [ ] 使用**个人** AWS 账号（不要用工作账号；Mac 上 `~/.aws/sso` 里如果有工作的登录缓存，不要混用）
- [ ] 根账号开启 MFA，日常操作用单独的 IAM 用户或 IAM Identity Center，不用根账号
- [ ] **AWS Budgets 预算告警：每月超过 10 美元发邮件**
- [ ] Mac 上安装 AWS CLI、Terraform；凭证只放在 `~/.aws/`，**绝不提交到仓库**
- [ ] `.gitignore` 加上 `*.tfstate`、`*.tfstate.*`、`.terraform/`、`*.tfvars`（state 文件里可能有敏感信息）

### 3.1 网络和机器

- [ ] VPC + 1 个可用区：公有子网（NLB、NAT）+ 私有子网（出价机器、监控机器）
- [ ] 出公网方式：先用 NAT 实例（t4g.nano，便宜）；对比 NAT Gateway 的费用
- [ ] Security Group：出价端口只允许 NLB / 压测机访问；SSH 只允许你自己的 IP，或改用 SSM Session Manager
- [ ] EC2：出价机器 c7g.large、压测机器 c7g.large、监控机器 t4g.small（全部 ARM，和虚拟机同架构）
- [ ] NLB（四层）→ 出价机器 8080，健康检查走 `/health`
- [ ] 所有资源打标签 `project=rtb-lab`

### 3.2 部署和验证

- [ ] Terraform 输出机器 IP → 生成 Ansible 清单 → 用阶段 2 的 playbook 部署
- [ ] 压测机器和出价机器分开后，重跑 1000 / 3000 / 5000 rps，对比虚拟机上的数据
- [ ] 在 EC2 上重跑 `verify-alerting.sh`
- [ ] 写记录：虚拟机 vs EC2 的延迟对比、费用实际花了多少

### 3.3 每次用完

- [ ] `terraform destroy`
- [ ] `terraform state list` 为空；控制台检查 EC2、负载均衡、NAT、弹性 IP 都没有残留
- [ ] 看一眼账单（按 `project=rtb-lab` 标签筛选）

**费用预估**（us-east-1，以 AWS 官网为准）：实验期间约 $0.10–0.30/小时；每周 2–3 次、用完就删，每月约 $3–10；忘记删除开一个月约 $70–220。

---

## 阶段 4：进阶（以后再说）

- [ ] 💤 接入 Redis（频次 / 预算），练习连接池、超时、下游变慢的排查
- [ ] 💤 Docker 对比实验：同一个竞价服务装进容器，对比延迟；在 `/sys/fs/cgroup` 里找到容器的 cgroup
- [ ] 💤 绑核实验（和高频交易方向接轨）：`taskset` / `isolcpus`，看 P99.9 抖动变化
- [ ] 💤 告警接入真实通知渠道（Slack / 邮件）
- [ ] 💤 更多故障：网卡软中断、吵闹邻居、DNS 变慢

---

## 规则（每次都遵守）

- **不经你同意不 `git push`**。可以在本地提交，然后问你要不要推。
- 密码、密钥、AWS 凭证、Terraform state 不进仓库。
- 项目定位：个人学习用的模拟项目（参考公开的 OpenRTB 流程），不说成生产经验。
- 做完一项就更新本文件。
