# Ansible 部署

用 playbook 部署整个 rtb-lab，替代 `deploy/deploy.sh` 和 `monitoring/install-monitoring.sh`。
同一份 playbook 以后部署到 EC2，只需要换一份机器清单（inventory）。

## 第一次使用（Mac 上）

```bash
# 1. 安装 Ansible：用 uv 装一个独立的 Python 3.12 环境，不碰系统 Python
python3 -m pip install --user uv
~/Library/Python/3.9/bin/uv tool install --python 3.12 ansible-core==2.21.4
# 可执行文件在 ~/.local/bin，建议加进 PATH：echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc

# 2. 安装用到的扩展（版本固定在 requirements.yml）
cd ansible
ansible-galaxy collection install -r requirements.yml

# 3. 测试能否连上机器
ansible all -m ping
```

## 日常命令（都在 ansible/ 目录下运行）

```bash
ansible-playbook site.yml                    # 部署全部
ansible-playbook site.yml --tags bidder      # 只部署竞价服务（改了 Java 代码以后）
ansible-playbook site.yml --tags monitoring  # 只部署监控、告警、日志
ansible-playbook site.yml --tags prometheus  # 只部署某一个组件
ansible-playbook site.yml --check --diff     # 预演：只显示会改什么，不真的改
```

## 目录结构

```
ansible/
├── ansible.cfg              默认配置（清单位置、SSH 连接复用）
├── requirements.yml         用到的扩展及版本
├── inventory/hosts.yml      机器清单：哪台机器担任什么角色
├── group_vars/all.yml       版本号、路径等变量（升级版本只改这里）
├── site.yml                 总 playbook：哪些机器装哪些角色
└── roles/
    ├── base/                Java 21、rsync 等基础软件包
    ├── rtb_code/            同步代码、编译（代码有变化才重新编译）
    ├── bidder/              竞价服务：用户、目录、systemd、健康检查
    ├── prom_binary/         通用：下载 Prometheus 系列二进制包并校验 SHA256
    ├── node_exporter/
    ├── alertmanager/        Alertmanager + 本地告警接收器
    ├── prometheus/          改配置或规则时只 reload，不重启
    ├── loki/
    ├── alloy/
    └── grafana/             软件源、管理员密码（只存在目标机器上）、数据源、大盘
```

配置文件**不复制一份**：角色直接引用仓库里 `monitoring/`、`deploy/` 下的原文件，只有一份来源。

## 和 bash 脚本相比

| | bash 脚本 | Ansible |
|---|---|---|
| 重复运行 | 每次都重启所有服务 | 只有文件真的变了才重启对应服务（handler） |
| 是否改动 | 看不出来 | 每一步报告 `ok` / `changed` / `failed` |
| 配置检查 | 先放到位再检查 | `validate`：先检查（promtool / amtool / loki / alloy），不通过就不替换 |
| 多台机器 | 要自己写循环 | 清单里加机器即可，并行执行 |
| 只改 Prometheus 规则 | 重启 Prometheus | `reload`（SIGHUP），抓取不中断 |

## 验证记录（2026-10-20，UTM 虚拟机）

- 第一次运行（从 bash 版部署迁移过来）：`ok=79 changed=18 failed=0`。二进制文件校验和一致，没有被替换；改动来自 Prometheus 的 `ExecReload`、Grafana 配置迁移到托管区块、文件权限统一。
- 第二次运行：`changed=0`（幂等）。
- 修过的一个幂等问题：编译会改动代码根目录的修改时间，rsync 每次都把它改回去，于是每次都显示"有变化"并重新编译。加 `--omit-dir-times` 解决。
- 部署后重跑 `monitoring/verify-alerting.sh`：配置检查、10 条规则、触发 / 恢复 / 静默 / 抑制全部通过，和 bash 版部署的结果一致。
