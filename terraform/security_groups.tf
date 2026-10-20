# 安全组：每类机器一个，只放行真正需要的端口。
# 没有任何一条规则开放 SSH（22）：登录全部走 SSM Session Manager。
#
#   压测 ──8080──→ 出价
#   监控 ──8080 /metrics、9100 node_exporter──→ 出价、压测
#   出价、压测 ──3100 Loki（Alloy 推日志）──→ 监控
#   所有机器出站不限（装软件、连 SSM、下载制品）

resource "aws_security_group" "bidder" {
  name        = "rtb-lab-bidder"
  description = "Bidder: 8080 from loadgen and monitoring; node_exporter from monitoring"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "rtb-lab-bidder" }
}

resource "aws_security_group" "loadgen" {
  name        = "rtb-lab-loadgen"
  description = "Load generator: node_exporter from monitoring only"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "rtb-lab-loadgen" }
}

resource "aws_security_group" "monitoring" {
  name        = "rtb-lab-monitoring"
  description = "Monitoring: Loki push from bidder and loadgen"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "rtb-lab-monitoring" }
}

locals {
  # 入站规则：目标安全组、端口、来源安全组、说明
  ingress_rules = {
    bid_from_loadgen        = { sg = aws_security_group.bidder.id, port = 8080, from = aws_security_group.loadgen.id, desc = "bid requests from loadgen" }
    metrics_from_monitoring = { sg = aws_security_group.bidder.id, port = 8080, from = aws_security_group.monitoring.id, desc = "Prometheus scrapes /metrics" }
    node_bidder             = { sg = aws_security_group.bidder.id, port = 9100, from = aws_security_group.monitoring.id, desc = "node_exporter" }
    node_loadgen            = { sg = aws_security_group.loadgen.id, port = 9100, from = aws_security_group.monitoring.id, desc = "node_exporter" }
    loki_from_bidder        = { sg = aws_security_group.monitoring.id, port = 3100, from = aws_security_group.bidder.id, desc = "Alloy pushes logs to Loki" }
    loki_from_loadgen       = { sg = aws_security_group.monitoring.id, port = 3100, from = aws_security_group.loadgen.id, desc = "Alloy pushes logs to Loki" }
  }
}

resource "aws_vpc_security_group_ingress_rule" "rules" {
  for_each                     = local.ingress_rules
  security_group_id            = each.value.sg
  referenced_security_group_id = each.value.from # 按安全组放行，而不是按 IP：机器换了 IP 规则依然成立
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
  description                  = each.value.desc
  tags                         = { Name = each.key }
}

resource "aws_vpc_security_group_egress_rule" "all_out" {
  for_each = {
    bidder     = aws_security_group.bidder.id
    loadgen    = aws_security_group.loadgen.id
    monitoring = aws_security_group.monitoring.id
  }
  security_group_id = each.value
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "all outbound (packages, SSM, S3)"
}
