# ===================================================================================
# SOC용 로그·지표 전송: WAS(api·vault) 파드 로그, 파드 CPU·메모리, DB(RDS) 로그
# - 파드 로그와 CPU·메모리: EKS 애드온 amazon-cloudwatch-observability (Fluent Bit + CloudWatch 에이전트)
# - DB 로그: RDS postgresql 로그를 CloudWatch로 내보내고, 접속·종료 기록을 켠다
# - 기본값은 꺼짐(enable_observability_logs = false). 켠 뒤 SOC가 읽을 수 있게 persistent/ 의
#   soc_reader_log_groups 에 아래 로그 그룹이 들어가 있어야 한다.
# - 앱 로그는 한 줄 JSON이고 토큰·비밀번호·서류 내용은 넣지 않는다(apps/*/web.py log()).
# ===================================================================================
variable "enable_observability_logs" {
  description = "true면 파드 로그·CPU/메모리(Container Insights)와 RDS 로그를 CloudWatch로 보낸다. 로그 그룹은 7일 보관"
  type        = bool
  default     = false
}

locals {
  obs_enabled = var.enable_observability_logs
  obs_log_groups = [
    "/aws/containerinsights/${module.eks.cluster_name}/application",
    "/aws/containerinsights/${module.eks.cluster_name}/performance",
    "/aws/containerinsights/${module.eks.cluster_name}/dataplane",
    "/aws/containerinsights/${module.eks.cluster_name}/host",
  ]
}

# 로그 그룹을 먼저 만들어 보관 기간을 7일로 고정한다(자동 생성되면 무기한 보관 → 비용, destroy 때 남음)
resource "aws_cloudwatch_log_group" "obs" {
  for_each          = local.obs_enabled ? toset(local.obs_log_groups) : toset([])
  name              = each.value
  retention_in_days = 7
}

# ---- 에이전트용 IRSA 역할 ------------------------------------------------------------
data "aws_iam_policy_document" "cw_agent_trust" {
  count = local.obs_enabled ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider}:sub"
      values   = ["system:serviceaccount:amazon-cloudwatch:cloudwatch-agent"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cw_agent" {
  count              = local.obs_enabled ? 1 : 0
  name               = "${var.project}-cloudwatch-agent"
  assume_role_policy = data.aws_iam_policy_document.cw_agent_trust[0].json
}

# AWS 관리형 CloudWatchAgentServerPolicy는 X-Ray·SSM·보관 기간 변경까지 포함해 넓다.
# 쓰기만, 미리 만든 로그 그룹 4개와 ContainerInsights 지표 이름공간으로 좁힌 정책을 쓴다.
resource "aws_iam_role_policy" "cw_agent" {
  count = local.obs_enabled ? 1 : 0
  name  = "ship-logs-and-metrics"
  role  = aws_iam_role.cw_agent[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "WriteContainerInsightsLogs"
        Effect = "Allow"
        Action = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
        Resource = flatten([for g in local.obs_log_groups : [
          "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:${g}",
          "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:${g}:*",
        ]])
      },
      {
        Sid      = "AgentChecksLogGroups"
        Effect   = "Allow"
        Action   = ["logs:DescribeLogGroups"]
        Resource = "*"
      },
      {
        Sid       = "WriteMetrics"
        Effect    = "Allow"
        Action    = ["cloudwatch:PutMetricData"]
        Resource  = "*"
        Condition = { StringEquals = { "cloudwatch:namespace" = "ContainerInsights" } }
      },
      {
        Sid      = "NodeVolumeTags"
        Effect   = "Allow"
        Action   = ["ec2:DescribeTags", "ec2:DescribeVolumes"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_eks_addon" "cloudwatch_observability" {
  count                    = local.obs_enabled ? 1 : 0
  cluster_name             = module.eks.cluster_name
  addon_name               = "amazon-cloudwatch-observability"
  addon_version            = "v8.0.1-eksbuild.1" # 고정(자동 최신 방지). 올릴 때는 PR로
  service_account_role_arn = aws_iam_role.cw_agent[0].arn

  # 노드가 있어야 파드가 뜬다. 로그 그룹이 먼저 있어야 보관 기간이 적용된다.
  depends_on = [module.eks, aws_cloudwatch_log_group.obs, aws_iam_role_policy.cw_agent]
}

# ---- RDS: 로그 내보내기 + 접속·종료 기록 ------------------------------------------------
resource "aws_cloudwatch_log_group" "rds" {
  count             = local.obs_enabled ? 1 : 0
  name              = "/aws/rds/instance/${var.project}-db/postgresql"
  retention_in_days = 7
}

resource "aws_db_parameter_group" "keeper" {
  count       = local.obs_enabled ? 1 : 0
  name        = "${var.project}-postgres16-logging"
  family      = "postgres16"
  description = "Log connections and disconnections for SOC monitoring" # RDS는 설명에 한글을 허용하지 않음

  parameter {
    name  = "log_connections"
    value = "1"
  }
  parameter {
    name  = "log_disconnections"
    value = "1"
  }
  # 오류가 난 쿼리의 문장을 로그에 남기지 않는다(기본은 error 이상이면 문장 기록).
  # 쿼리 기록(log_statement)과 느린 쿼리(log_min_duration_statement)는 기본값(꺼짐) 그대로 둔다.
  parameter {
    name  = "log_min_error_statement"
    value = "panic"
  }
}
