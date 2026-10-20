# rtb-lab 任务清单

> 这是整个项目唯一的任务清单。每做完一步就在这里打勾，并写上日期和提交号。
> 最后更新：2026-10-20

状态说明：✅ 完成 · 🟡 进行中 · ⬜ 未开始 · 💤 以后再说

**目标岗位**：小型量化交易公司的 Senior Infrastructure / Systems Engineer。他们的环境是约 5 台 EC2 + S3 + SSM + Ansible + Linux，不用 Kubernetes，强调简单、可靠、可重现、安全。下面的顺序按这个岗位的要求排列。

---

## 当前状态一览

| 阶段 | 内容 | 对应岗位要求 | 状态 |
|---|---|---|---|
| A | 基础：虚拟机、竞价服务、压测、监控、告警、日志 | 监控、日志、故障分析 | ✅ |
| B | Ansible：部署脚本改成 playbook | Ansible 配置管理 | ✅ |
| 1 | 版本化部署 + 自动回滚（虚拟机） | 部署和回滚流程 | ✅ |
| 2 | EC2 + IAM 角色 + SSM + S3 + Parameter Store | EC2 / VPC / IAM / S3 / SSM、凭证管理 | ⬜ 等 AWS 账号准备 |
| 3 | 故障实验：OOM、fd、丢包 | 跨应用 / 系统 / 网络排查 | ⬜ |
| 4 | 调优：绑核、IRQ、ENA 网卡计数器、TCP 参数、NUMA | Linux 性能调优（加分项） | ⬜ |
| 5 | 交易所行情连接 + 多区域延迟对比 + 时间同步 | 交易所连接、多区域（加分项） | ⬜ |
| 6 | 备份恢复演练、runbook、成本报告 | 备份恢复、事故响应、成本优化 | ⬜ |

---

## 阶段 A：基础 ✅

- [x] UTM 虚拟机 Rocky 9（4 核 4 GB），SSH 免密登录 `ssh rocky9`（2026-10-19）
- [x] 竞价服务 Bidder（Java 21，systemd 管理）+ 开环压测程序 LoadGen（`55b9347`）
- [x] 排查记录 #01：5000 rps 时 TCP 连接反复重建，P99 60 ms → 5.6 ms（`a4e63c8`）
- [x] Prometheus + node_exporter + Grafana 大盘（`39aecb5`）
- [x] Alertmanager + 10 条告警规则 + 本地告警接收器（`920d97e`）
- [x] 验证记录 #02：告警触发 / 恢复 / 静默 / 抑制全部验证通过（`920d97e`）
- [x] Loki + Alloy 集中日志（`ea12659`）；大盘日志面板和无数据说明文字（`76ac64f`）
- [x] 讨论稿 `docs/why-chain-oom-and-fd.md`（`7c6032f`）
- [x] 发布到 GitHub：github.com/hwang-protocol/rtb-lab（公开）
- [x] 流程图网页（私有链接，需要时在 Share 菜单里分享）：https://claude.ai/artifact/99pYCpwdwiuVeftBjr9jsq

## 阶段 B：Ansible ✅

- [x] ansible-core 2.21.4 + ansible.posix 2.2.2（uv + Python 3.12，不依赖 Homebrew）
- [x] 角色：`base`、`rtb_code`、`bidder`、`prom_binary`、`node_exporter`、`alertmanager`、`prometheus`、`loki`、`alloy`、`grafana`
- [x] 配置先检查再替换（`validate`）；Prometheus 改规则只 reload
- [x] 幂等：第二次运行 `changed=0`；`verify-alerting.sh` 全部通过（`6906f13`、`eb5af31`、`09ba2ae`）

---

## 阶段 1：版本化部署 + 自动回滚（虚拟机，免费）✅

- [x] 竞价服务报告版本：`/health` 返回 `ok <版本>`；指标 `bidder_build_info{version=...}`（`a3a9e5d`）
- [x] `build.yml`：按 git 提交号打包 + SHA256；有未提交的改动拒绝构建（`-e allow_dirty=true` 强制）（`93b5e71`）
- [x] 目录结构 `releases/<版本>/` + `current` 符号链接 + `HISTORY`；只保留最近 5 个版本
- [x] `deploy.yml`：校验 SHA256 → 切换 → 重启 → 版本号健康检查 + 冒烟测试；失败自动回滚；已是该版本则跳过；`serial: 1`
- [x] `rollback.yml`：回到上一个成功发布过的版本，或 `-e version=`
- [x] 演练记录 #03：坏版本自动回滚；加"发现反复崩溃立刻失败"后，中断 28 秒 → 3 秒，失败请求减少 89%
- [x] 正常切换版本的代价：单机每次约 0.15 秒中断；零中断要等阶段 2 的多台机器 + NLB
- [x] 删除旧的 bash 部署脚本，README 改成 Ansible 命令
- [ ] 💤 切换前预热 JVM，看能否消除切换后 P99.9 约 200 ms 的冷启动尖峰

---

## 阶段 2：EC2 + IAM 角色 + SSM + S3 + Parameter Store（花钱，每次用完必须销毁）

### 2.0 开始之前（你在 AWS 控制台操作）

- [x] 使用**个人** AWS 账号（免费套餐：额度 $120，**2027-04-20 到期**，到期前要决定是否升级，否则账号会被关闭）
- [x] 根账号开启 MFA；根账号没有长期密钥（2026-10-20 用 CLI 核对）
- [x] **AWS Budgets 预算 `rtb-lab-monthly-10usd`**：每月 10 美元，按实际用量计算（不扣免费额度），实际 50% / 100% 和预测 100% 时发邮件
- [x] 日常使用的 IAM 用户 `hongzheng`（控制台密码 + MFA，0 个 Access Key）；CLI：`aws login --profile rtb-lab`，临时凭证
  - 没有用 IAM Identity Center：开启它会自动创建 Organization，账号会升级为付费、免费额度立刻作废（2026-10-20 在控制台确认）
- [x] Mac 上安装 AWS CLI 2.38.0（Amazon 签名已校验）、Terraform 1.16.5（SHA256 已校验），都在 `~/.local/bin`；没有长期凭证
- [x] `.gitignore` 加上 `*.tfstate`、`*.tfstate.*`、`.terraform/`、`*.tfvars`、`tfplan`；`.terraform.lock.hcl` 进仓库

### 2.1 网络和机器（Terraform，保持简单）

- [x] VPC 10.20.0.0/16 + 1 个可用区（us-east-1a）：公有子网 + 私有子网；默认安全组清空（2026-10-20 已创建，Terraform 1.16.5 / AWS provider 6.67.0）
- [ ] **不开 SSH 端口**：所有登录走 SSM Session Manager
- [x] Security Group：按安全组互相放行（8080、9100、3100），没有任何 SSH 规则；NLB 的规则等加 NLB 时再加
- [ ] EC2：出价 c7g.large、压测 c7g.large、监控 t4g.small（全部 ARM）
- [x] 每类机器一个 **IAM 实例角色**，最小权限；用 IAM 策略模拟器验证
  - 发现：`AmazonSSMManagedInstanceCore` 允许读**任何**参数 → 加显式 Deny，各角色不能读其他角色的 `/rtb-lab/<角色>/` 参数
- [x] S3 制品桶：禁止公开访问、加密、版本控制、只允许 HTTPS、旧版本 30 天删除
- [x] 所有资源打标签 `project=rtb-lab`（provider 的 default_tags）

### 2.2 按岗位的方式部署

- [ ] Ansible 通过 SSM 连接机器（不走 SSH）
- [ ] 制品上传 S3，`deploy.yml` 从 S3 下载并校验
- [ ] Grafana 密码等密钥放 **SSM Parameter Store**（加密），机器用角色读取
- [ ] 压测机器和出价机器分开后，重跑 1000 / 3000 / 5000 rps，和虚拟机对比
- [ ] 重跑 `verify-alerting.sh`；写记录：虚拟机 vs EC2 延迟对比、实际花费

### 2.3 每次用完

- [ ] `terraform destroy`；`terraform state list` 为空；控制台确认没有残留（EC2、负载均衡、NAT、弹性 IP）
- [ ] 看一眼账单（按 `project=rtb-lab` 标签筛选）

**费用预估**（us-east-1，以 AWS 官网为准）：实验期间约 $0.10–0.30/小时；每周 2–3 次、用完就删，每月约 $3–10；忘记删除开一个月约 $70–220。

---

## 阶段 3：故障实验

每个实验都写一份排查记录（`results/`，格式同 #01）：现象 → 定位 → 根因 → 修复 → 前后数据对比。

- [ ] **内存泄漏 → OOM**（书第 13 章）：`-Xmx` 先满 vs cgroup `MemoryMax` 先满；`ExitOnOutOfMemoryError`；堆使用率告警
- [ ] **fd 耗尽**：`LimitNOFILE` 太低 vs fd 泄漏，两种曲线对比；fd 使用率告警
- [ ] **丢包和网络延迟**：`tc netem` 注入延迟 / 丢包，用 `tcpdump`、`ss -ti`（重传）、大盘定位
- [ ] 💤 磁盘写满 + LVM 在线扩容

## 阶段 4：调优（在 EC2 上做，每项都对比 P99 / P99.9）

- [ ] CPU 绑核（`CPUAffinity`、`taskset`）、`isolcpus`
- [ ] 中断亲和性（IRQ affinity）、RPS / XPS
- [ ] ENA 网卡计数器：`ethtool -S` 里的 `pps_allowance_exceeded` 等（EC2 按实例限制包速率，超了会悄悄丢包）
- [ ] TCP 参数（`sysctl`：缓冲区、连接队列）
- [ ] NUMA：在大实例上用 `numactl --hardware` 看结构（书第 2 章）

## 阶段 5：交易所连接 + 多区域

- [ ] 连接交易所**公开行情** WebSocket（不交易、不开账户）：消息延迟、断线次数、自动重连，接入 Prometheus
- [ ] 2–3 个 AWS 区域各开一台小机器，对比到交易所的延迟
- [ ] chrony + Amazon Time Sync Service，监控时钟偏差

## 阶段 6：可靠性收尾

- [ ] 备份恢复演练：删掉一台机器，用 Terraform + Ansible 从零重建，记录恢复时间
- [ ] 每条告警写 runbook（现象、检查命令、处理步骤）
- [ ] 成本报告：实际账单、优化了什么（Graviton、gp3、NAT 实例代替 NAT Gateway、用完销毁）

## 以后再说 💤

- [ ] 接入 Redis（频次 / 预算），练习连接池、超时、下游变慢
- [ ] Docker 对比实验（知道为什么这个岗位不用它）
- [ ] 告警接入 Slack / 邮件

---

## 规则（每次都遵守）

- **不经你同意不 `git push`**。可以在本地提交，然后问你要不要推。
- 密码、密钥、AWS 凭证、Terraform state 不进仓库。
- 项目定位：个人学习用的模拟项目（参考公开的 OpenRTB 流程），不说成生产经验。
- 做完一项就更新本文件。
