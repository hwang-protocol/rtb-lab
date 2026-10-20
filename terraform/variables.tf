variable "region" {
  description = "AWS 区域"
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "~/.aws/config 里的 profile（aws login --profile rtb-lab）"
  type        = string
  default     = "rtb-lab"
}

variable "vpc_cidr" {
  description = "VPC 地址段"
  type        = string
  default     = "10.20.0.0/16"
}
