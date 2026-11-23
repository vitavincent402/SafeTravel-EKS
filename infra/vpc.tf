# VPC: 가용 영역 2곳, 퍼블릭(ALB·NAT) / 프라이빗(EKS 노드) / 데이터(RDS) 서브넷
locals {
  azs              = ["${var.region}a", "${var.region}c"]
  vpc_cidr         = "10.0.0.0/16"
  public_subnets   = ["10.0.0.0/24", "10.0.1.0/24"]
  private_subnets  = ["10.0.10.0/24", "10.0.11.0/24"]
  database_subnets = ["10.0.20.0/24", "10.0.21.0/24"]
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.13"

  name = "${var.project}-vpc"
  cidr = local.vpc_cidr
  azs  = local.azs

  public_subnets   = local.public_subnets
  private_subnets  = local.private_subnets
  database_subnets = local.database_subnets

  create_database_subnet_group       = true
  create_database_subnet_route_table = true # 데이터 서브넷은 인터넷 경로 없음

  enable_nat_gateway   = true
  single_nat_gateway   = true # 비용 때문에 1개 (AZ-a)
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Load Balancer Controller가 ALB를 만들 서브넷을 찾는 태그
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
}
