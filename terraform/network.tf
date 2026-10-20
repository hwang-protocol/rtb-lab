# 网络：1 个 VPC、1 个可用区。
#   公有子网：以后放 NLB 和 NAT 实例（能直接上公网）
#   私有子网：以后放出价、压测、监控机器（没有公网 IP，外面访问不到）
# 实验环境只用 1 个可用区：跨可用区的流量要收费，而且这里不追求机房级容灾。

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  az = data.aws_availability_zones.available.names[0]
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true # SSM 等服务依赖 DNS 主机名
  tags                 = { Name = "rtb-lab" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 0) # 10.20.0.0/24
  availability_zone       = local.az
  map_public_ip_on_launch = false # 公网 IP 按需单独分配，不自动给
  tags                    = { Name = "rtb-lab-public" }
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 1) # 10.20.1.0/24
  availability_zone = local.az
  tags              = { Name = "rtb-lab-private" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "rtb-lab" }
}

# 公有子网：默认路由走互联网网关
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "rtb-lab-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# 私有子网：现在只能在 VPC 内部通信。
# 下一步建 EC2 时再加出公网的方式（NAT 实例），机器装软件、连 SSM 都靠它。
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "rtb-lab-private" }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# 默认安全组：去掉 AWS 自带的"组内互通"规则，避免有资源误用它
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "rtb-lab-default-unused" }
}
