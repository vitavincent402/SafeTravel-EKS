# SOC 서버가 감사 로그·WAF 로그를 읽는 역할 (AssumeRole + ExternalId).
# 사람 IAM 사용자용 keeper-log-read(scripts/grant-log-read.ps1)와는 별개다.
# 클러스터와 로그 그룹은 매일 다시 만들어지지만, 이 역할은 persistent/에 있어서 이름과 신뢰 설정이 그대로 유지된다.
# 권한은 로그 그룹 "이름"에 걸어서, 그룹이 다시 만들어져도 그대로 적용된다.
#
# 켜는 순서: SOC가 개인 채널로 준 신뢰 주체(ARN)와 ExternalId를 persistent/terraform.tfvars(gitignore)에 넣고 apply.
#   soc_reader_trusted_arn  = "arn:aws:iam::<SOC 계정>:role/<SOC 서버 역할>"
#   soc_reader_external_id  = "<SOC가 준 값>"
# 두 값이 모두 있어야 만들어진다. ExternalId는 Terraform state에 평문으로 들어가므로 저장소에 올리지 않는다.
variable "soc_reader_trusted_arn" {
  description = "SOC 서버가 이 역할을 맡을 때 쓰는 IAM 주체(역할 또는 사용자) ARN. 비우면 역할을 만들지 않는다"
  type        = string
  default     = ""
}

variable "soc_reader_external_id" {
  description = "SOC가 정한 ExternalId(혼동된 대리인 방지). 비우면 역할을 만들지 않는다"
  type        = string
  default     = ""
  sensitive   = true
}

variable "soc_reader_log_groups" {
  description = "SOC 서버가 읽을 CloudWatch 로그 그룹 이름"
  type        = list(string)
  default = [
    "/aws/eks/keeper-eks/cluster", "aws-waf-logs-keeper", "aws-waf-logs-cognito",
    # 파드 로그·CPU/메모리(application·performance)와 DB 로그. infra/observability.tf 를 켜면 생긴다
    "/aws/containerinsights/keeper-eks/application", "/aws/containerinsights/keeper-eks/performance",
    "/aws/rds/instance/keeper-db/postgresql",
    # 계정 잠금 Lambda 로그(account_lock.tf). 그룹이 없어도(꺼짐) 권한은 이름으로 걸려 있어 문제없다
    "/aws/lambda/keeper-account-lock",
  ]
}

locals {
  # 값이 들어 있는지(true/false)만 쓰므로 sensitive 표시를 벗겨도 ExternalId가 드러나지 않는다
  soc_reader_enabled = nonsensitive(var.soc_reader_trusted_arn != "" && var.soc_reader_external_id != "")
}

resource "aws_iam_role" "soc_reader" {
  count = local.soc_reader_enabled ? 1 : 0

  name                 = "${var.name}-soc-reader"
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = var.soc_reader_trusted_arn }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "sts:ExternalId" = var.soc_reader_external_id }
      }
    }]
  })
}

resource "aws_iam_role_policy" "soc_reader" {
  count = local.soc_reader_enabled ? 1 : 0

  name = "read-keeper-logs"
  role = aws_iam_role.soc_reader[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadKeeperLogGroups"
        Effect = "Allow"
        Action = ["logs:FilterLogEvents", "logs:GetLogEvents", "logs:DescribeLogStreams", "logs:StartQuery"]
        Resource = flatten([
          for g in var.soc_reader_log_groups : [
            "arn:aws:logs:${var.region}:${data.aws_caller_identity.this.account_id}:log-group:${g}",
            "arn:aws:logs:${var.region}:${data.aws_caller_identity.this.account_id}:log-group:${g}:*",
          ]
        ])
      },
      {
        Sid      = "ListAndQueryResults"
        Effect   = "Allow"
        Action   = ["logs:DescribeLogGroups", "logs:GetQueryResults", "logs:StopQuery"]
        Resource = "*"
      },
      {
        # ALB 접속 로그 버킷 읽기만(쓰기·삭제 없음). 쿼리 문자열이 들어 있으니 SOC 수집기가 읽자마자 버린다
        Sid      = "ReadAlbAccessLogs"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.alb_logs.arn}/*"
      },
      {
        Sid      = "ListAlbAccessLogs"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.alb_logs.arn
      },
      {
        # 노드(EC2) CPU·네트워크·디스크 I/O 지표 읽기용. GetMetricData는 지표 단위로 제한할 수 없어 계정의 모든 지표를 읽을 수 있다(읽기 전용)
        Sid      = "ReadMetrics"
        Effect   = "Allow"
        Action   = ["cloudwatch:GetMetricData"]
        Resource = "*"
      },
    ]
  })
}

output "soc_reader_role_arn" {
  description = "SOC 서버가 맡을 역할 ARN (soc_reader_* 값을 넣었을 때만)"
  value       = local.soc_reader_enabled ? aws_iam_role.soc_reader[0].arn : ""
}
