terraform {
  required_version = "~> 1.16"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.67.0" # 固定版本：升级要手动改这里并重新 init
    }
  }
  # state 先放本地（terraform.tfstate，已在 .gitignore 里）。一个人做实验够用；
  # 多人协作时改成 S3 backend + 锁，避免两个人同时修改。
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile # 用 aws login 得到的临时凭证，不用 Access Key

  # 所有资源自动打上这些标签：账单里按 project=rtb-lab 筛选
  default_tags {
    tags = {
      project    = "rtb-lab"
      managed-by = "terraform"
    }
  }
}
