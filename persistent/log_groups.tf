# ===================================================================================
# 로그 그룹 (매일 destroy 대상 아님)
# - infra/ 가 매일 destroy되면서 로그 그룹이 기록째 지워져 SOC 감사 증적이 사라지던 문제 대책.
# - infra/ 의 EKS·WAF·Fluent Bit·RDS는 아래 이름의 그룹에 계속 쓴다(이름으로 참조). 이름을 바꾸면 SOC 수집이 끊긴다.
# - 보관 7일. 그룹이 남아도 기록은 7일 뒤 자동 삭제된다.
# - 처음 한 번 import 블록이 infra/ 가 만들어 둔 그룹을 가져온다(지웠다 다시 만들지 않음 → 기록 유지).
#   이미 state에 있으면 import 블록은 아무 일도 하지 않는다.
# ===================================================================================
variable "keeper_cluster_name" {
  description = "infra/ 의 EKS 클러스터 이름. 로그 그룹 이름에 들어간다"
  type        = string
  default     = "keeper-eks"
}

locals {
  keeper_log_groups = toset([
    "/aws/eks/${var.keeper_cluster_name}/cluster",                   # EKS 제어 기록(api, audit, authenticator)
    "aws-waf-logs-keeper",                                           # ALB WAF (이름은 aws-waf-logs- 로 시작해야 함)
    "/aws/containerinsights/${var.keeper_cluster_name}/application", # 파드 로그
    "/aws/containerinsights/${var.keeper_cluster_name}/performance", # 파드 CPU·메모리
    "/aws/containerinsights/${var.keeper_cluster_name}/dataplane",
    "/aws/containerinsights/${var.keeper_cluster_name}/host",
    "/aws/rds/instance/keeper-db/postgresql", # DB 로그
  ])
}

resource "aws_cloudwatch_log_group" "keeper" {
  for_each          = local.keeper_log_groups
  name              = each.value
  retention_in_days = 7
}

import {
  for_each = local.keeper_log_groups
  to       = aws_cloudwatch_log_group.keeper[each.value]
  id       = each.value
}
