# 每类机器一个 IAM 实例角色：机器上的程序用角色拿临时凭证访问 AWS，机器上不放任何密钥。
# 权限按最小原则：
#   所有机器：SSM 登录和管理（AWS 托管策略 AmazonSSMManagedInstanceCore）
#   出价机器：只能下载 S3 制品桶里 bidder/ 下的文件
#   压测机器：只能下载 loadgen/ 下的文件
#   监控机器：只能读 SSM Parameter Store 里 /rtb-lab/monitoring/ 下的参数（Grafana 密码）
# 上传制品是人（hongzheng）或以后的构建机的事，机器本身都不能写 S3。

locals {
  roles = {
    bidder     = { s3_prefix = "bidder/", ssm_params = null }
    loadgen    = { s3_prefix = "loadgen/", ssm_params = null }
    monitoring = { s3_prefix = null, ssm_params = "/rtb-lab/monitoring/*" }
  }
}

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "host" {
  for_each           = local.roles
  name               = "rtb-lab-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  for_each   = local.roles
  role       = aws_iam_role.host[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "read_artifacts" {
  for_each = { for k, v in local.roles : k => v if v.s3_prefix != null }
  statement {
    sid       = "ReadOwnArtifacts"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.artifacts.arn}/${each.value.s3_prefix}*"]
  }
  statement {
    sid       = "ListOwnPrefix"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.artifacts.arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${each.value.s3_prefix}*"]
    }
  }
}

resource "aws_iam_role_policy" "read_artifacts" {
  for_each = data.aws_iam_policy_document.read_artifacts
  name     = "read-artifacts"
  role     = aws_iam_role.host[each.key].id
  policy   = each.value.json
}

data "aws_iam_policy_document" "read_params" {
  for_each = { for k, v in local.roles : k => v if v.ssm_params != null }
  statement {
    sid       = "ReadOwnParameters"
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = ["arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${each.value.ssm_params}"]
  }
}

resource "aws_iam_role_policy" "read_params" {
  for_each = data.aws_iam_policy_document.read_params
  name     = "read-parameters"
  role     = aws_iam_role.host[each.key].id
  policy   = each.value.json
}

# 注意：AmazonSSMManagedInstanceCore 自带 ssm:GetParameter(s)，资源是 "*"，
# 也就是说只靠上面的 Allow，出价机器照样能读监控机器的密码（2026-10-20 用 IAM 策略模拟器发现）。
# 所以再加一条显式 Deny：每个角色都不能读其他角色名下 /rtb-lab/<角色>/ 的参数。显式 Deny 永远优先于 Allow。
data "aws_iam_policy_document" "deny_other_params" {
  for_each = local.roles
  statement {
    sid     = "DenyOtherRolesParameters"
    effect  = "Deny"
    actions = ["ssm:GetParameter*"]
    resources = [
      for other in keys(local.roles) :
      "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/rtb-lab/${other}/*"
      if other != each.key
    ]
  }
}

resource "aws_iam_role_policy" "deny_other_params" {
  for_each = data.aws_iam_policy_document.deny_other_params
  name     = "deny-other-roles-parameters"
  role     = aws_iam_role.host[each.key].id
  policy   = each.value.json
}

resource "aws_iam_instance_profile" "host" {
  for_each = local.roles
  name     = "rtb-lab-${each.key}"
  role     = aws_iam_role.host[each.key].name
}
