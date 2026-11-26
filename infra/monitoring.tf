# =========================================================
# 가용성 감시 (CloudWatch Synthetics) + 알림 + 대시보드   [WEB 담당]
# 5분마다 바깥에서 첫 화면, web 상태, 보안 헤더, api→vault 경로, 로그인 화면을 확인하고
# 연속 2번 실패하면 알림을 보낸다.
#
# - 클러스터와 같이 만들고 같이 지운다. 앱 배포(bootstrap_deploy)가 끝난 뒤에 시작하고, destroy 때는 가장 먼저 지워진다.
# - 기본값은 꺼짐(monitoring_enabled = false). 켜려면 terraform.tfvars 에 monitoring_enabled = true.
# - 켜는 순서(조장과 합의): 첫 apply는 끈 채로 → 따로 한 번 켜서 시험 → 리허설부터 켬 → 시연 당일은 시험을 마친 상태로 켬.
# - 알림은 persistent/ 의 SNS 주제(출력 alert_topic_arn)를 받아 쓴다. 구독 확인을 한 번만 누르면 됨.
# - 비용: 실행 1회 약 $0.0012. 5분 간격이면 켜 둔 시간 1시간에 약 $0.015 (하루 8시간이면 약 $0.12).
# =========================================================

variable "monitoring_enabled" {
  description = "가용성 감시(카나리·알람·대시보드)를 만들지. 앱 배포(run_bootstrap_deploy = true)와 함께 써야 함"
  type        = bool
  default     = false
}

variable "canary_interval_minutes" {
  description = "감시 간격(분)"
  type        = number
  default     = 5
}

variable "alert_topic_arn" {
  description = "알림을 보낼 SNS 주제 ARN (destroy 되지 않는 곳에 만든 것). 있으면 이걸 쓰고, 비우면 alert_email 로 여기서 주제를 만든다"
  type        = string
  default     = ""
}

variable "alert_email" {
  description = "alert_topic_arn 이 없을 때 알림 받을 이메일. 값은 terraform.tfvars 에만 적고 Git 에 올리지 않는다. 매번 새로 만들면 구독 확인 메일을 다시 눌러야 함"
  type        = string
  default     = ""
}

locals {
  monitor     = var.monitoring_enabled && var.run_bootstrap_deploy
  canary_name = "${var.project}-web-check" # 이름은 21자 이하
  # 도메인이 있으면 HTTPS 주소, 없으면 ALB 주소로 HTTP
  monitor_url = !local.monitor ? "" : (
    local.use_domain ? "https://${var.domain_name}" : "http://${data.aws_lb.monitor[0].dns_name}"
  )
  # 로그인 확인은 Cognito에 등록된 주소(도메인)로 감시할 때만
  monitor_login = local.use_domain && var.cognito_login_domain != "" && var.cognito_client_id != ""
  # 알림 주제: 밖에서 받은 것 > 여기서 만든 것 > 없음
  alert_topic = var.alert_topic_arn != "" ? var.alert_topic_arn : (
    local.monitor && var.alert_email != "" ? aws_sns_topic.alerts[0].arn : ""
  )
}

# ---- 앱 배포 뒤 ALB 찾기 (dns.tf 와 같은 방법) ----
data "aws_lb" "monitor" {
  count = local.monitor ? 1 : 0
  tags = {
    "elbv2.k8s.aws/cluster" = module.eks.cluster_name
    "ingress.k8s.aws/stack" = "keeper"
  }
  depends_on = [terraform_data.bootstrap_deploy]
}

# ---- 결과(로그·응답 기록)를 담는 비공개 버킷 ----
resource "aws_s3_bucket" "canary" {
  count         = local.monitor ? 1 : 0
  bucket_prefix = "${var.project}-canary-"
  force_destroy = true # destroy 때 결과 파일이 있어도 삭제
}

resource "aws_s3_bucket_public_access_block" "canary" {
  count                   = local.monitor ? 1 : 0
  bucket                  = aws_s3_bucket.canary[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "canary" {
  count  = local.monitor ? 1 : 0
  bucket = aws_s3_bucket.canary[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "canary" {
  count  = local.monitor ? 1 : 0
  bucket = aws_s3_bucket.canary[0].id
  rule {
    id     = "expire-old-results"
    status = "Enabled"
    filter {}
    expiration {
      days = 14
    }
  }
}

# ---- 실행 역할: 자기 결과 버킷, 자기 로그, 지표 전송만 ----
resource "aws_iam_role" "canary" {
  count = local.monitor ? 1 : 0
  name  = "${var.project}-canary"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "canary" {
  count = local.monitor ? 1 : 0
  name  = "canary-minimum"
  role  = aws_iam_role.canary[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.canary[0].arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetBucketLocation"]
        Resource = aws_s3_bucket.canary[0].arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListAllMyBuckets"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/cwsyn-${local.canary_name}-*"
      },
      {
        Effect    = "Allow"
        Action    = ["cloudwatch:PutMetricData"]
        Resource  = "*"
        Condition = { StringEquals = { "cloudwatch:namespace" = "CloudWatchSynthetics" } }
      }
    ]
  })
}

# ---- 감시 스크립트 묶기 ----
data "archive_file" "canary" {
  type        = "zip"
  source_dir  = "${path.module}/canary"
  output_path = "${path.module}/.build/canary.zip"
}

resource "aws_synthetics_canary" "web" {
  count                = local.monitor ? 1 : 0
  name                 = local.canary_name
  artifact_s3_location = "s3://${aws_s3_bucket.canary[0].bucket}/canary/"
  execution_role_arn   = aws_iam_role.canary[0].arn
  handler              = "index.handler"
  zip_file             = data.archive_file.canary.output_path
  runtime_version      = "syn-nodejs-puppeteer-18.0"
  start_canary         = true
  delete_lambda        = true # destroy 때 카나리가 만든 Lambda 도 같이 지움

  success_retention_period = 2
  failure_retention_period = 14

  schedule {
    expression = "rate(${var.canary_interval_minutes} minutes)"
  }

  run_config {
    timeout_in_seconds = 60
    memory_in_mb       = 960
    environment_variables = {
      TARGET_URL      = local.monitor_url
      LOGIN_DOMAIN    = local.monitor_login ? var.cognito_login_domain : ""
      LOGIN_CLIENT_ID = local.monitor_login ? var.cognito_client_id : ""
    }
  }

  depends_on = [aws_iam_role_policy.canary, terraform_data.bootstrap_deploy]
}

# ---- 카나리 실행 로그 그룹: 7일 보관 + destroy 때 삭제 ----
# 카나리 Lambda가 /aws/lambda/cwsyn-<이름>-<카나리 ID> 그룹을 스스로 만든다. 보관 기간이 무기한이고
# Terraform 밖이라 destroy 뒤에도 남아, 구축마다 이름이 다른 그룹이 쌓였다.
# 이름에 매번 바뀌는 카나리 ID가 들어가 persistent/ 에 미리 만들 수 없으므로, 카나리를 만든 뒤 7일 보관을 걸고
# destroy 때 지운다(카나리 결과 S3 버킷도 매일 지워지므로 같은 수명).
# 그룹 이름 = /aws/lambda/cwsyn-<카나리 이름>-<카나리 Id>. Id는 Terraform 속성으로 나오지 않아(engine_arn도 비어 있음) CLI로 조회한다.
locals {
  canary_ps_group   = "$id = aws synthetics get-canary --name $env:CANARY --query Canary.Id --output text; if (-not $id -or $id -eq 'None') { exit 1 }; $g = \"/aws/lambda/cwsyn-$($env:CANARY)-$id\""
  canary_bash_group = "id=$(aws synthetics get-canary --name \"$CANARY\" --query Canary.Id --output text) && [ -n \"$id\" ] && [ \"$id\" != None ] && g=\"/aws/lambda/cwsyn-$CANARY-$id\""
}

resource "terraform_data" "canary_log_group" {
  count = local.monitor ? 1 : 0
  input = {
    canary     = aws_synthetics_canary.web[0].id # 카나리 이름. 카나리가 바뀌면 다시 실행
    region     = var.region
    windows    = local.is_windows
    ps_group   = local.canary_ps_group
    bash_group = local.canary_bash_group
  }

  # 카나리 첫 실행이 먼저 그룹을 만들었을 수 있으므로 만들기 실패(이미 있음)는 무시하고 보관 기간만 확실히 건다
  provisioner "local-exec" {
    interpreter = self.input.windows ? ["PowerShell", "-Command"] : ["bash", "-c"]
    environment = { CANARY = self.input.canary, AWS_REGION = self.input.region }
    command = self.input.windows ? join("; ", [
      self.input.ps_group,
      "aws logs create-log-group --log-group-name $g 2>$null",
      "aws logs put-retention-policy --log-group-name $g --retention-in-days 7",
      "if ($LASTEXITCODE -ne 0) { exit 1 }",
      "Write-Output \"retention 7d: $g\"",
      ]) : join(" && ", [
      self.input.bash_group,
      "{ aws logs create-log-group --log-group-name \"$g\" 2>/dev/null || true; }",
      "aws logs put-retention-policy --log-group-name \"$g\" --retention-in-days 7",
      "echo \"retention 7d: $g\"",
    ])
  }

  # destroy 때 카나리보다 먼저 실행되므로 Id를 아직 조회할 수 있다. 실패해도 destroy는 계속한다
  provisioner "local-exec" {
    when        = destroy
    interpreter = self.input.windows ? ["PowerShell", "-Command"] : ["bash", "-c"]
    environment = { CANARY = self.input.canary, AWS_REGION = self.input.region }
    command     = self.input.windows ? "${self.input.ps_group}; aws logs delete-log-group --log-group-name $g 2>$null; exit 0" : "${self.input.bash_group} && aws logs delete-log-group --log-group-name \"$g\" 2>/dev/null; true"
  }
}

# ---- 알림 주제 (alert_topic_arn 이 없을 때만 여기서 만든다) ----
resource "aws_sns_topic" "alerts" {
  count = local.monitor && var.alert_topic_arn == "" && var.alert_email != "" ? 1 : 0
  name  = "${var.project}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  count     = length(aws_sns_topic.alerts)
  topic_arn = aws_sns_topic.alerts[0].arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ---- 알람: 연속 2번 실패하면 알림, 회복하면 정상 알림 ----
resource "aws_cloudwatch_metric_alarm" "canary_failed" {
  count               = local.monitor ? 1 : 0
  alarm_name          = "${var.project}-web-check-failed"
  alarm_description   = "SafeTravel Keeper 가용성 감시가 연속 2번 실패했습니다. (첫 화면, web 상태, 보안 헤더, api→vault, 로그인 화면 중 하나). 카나리 로그에서 FAIL 줄을 확인하세요."
  namespace           = "CloudWatchSynthetics"
  metric_name         = "SuccessPercent"
  statistic           = "Average"
  period              = var.canary_interval_minutes * 60
  evaluation_periods  = 2
  threshold           = 100
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching" # 감시 자체가 멈춰도 알린다
  alarm_actions       = local.alert_topic == "" ? [] : [local.alert_topic]
  ok_actions          = local.alert_topic == "" ? [] : [local.alert_topic]

  dimensions = {
    CanaryName = local.canary_name
  }

  depends_on = [aws_synthetics_canary.web]
}

# ---- 대시보드: 감시 결과 + ALB 상태를 한 화면에 ----
resource "aws_cloudwatch_dashboard" "keeper" {
  count          = local.monitor ? 1 : 0
  dashboard_name = "${var.project}-availability"
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title   = "가용성 감시 성공률 (%)"
          region  = var.region
          stat    = "Average"
          period  = var.canary_interval_minutes * 60
          metrics = [["CloudWatchSynthetics", "SuccessPercent", "CanaryName", local.canary_name]]
          yAxis   = { left = { min = 0, max = 100 } }
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title   = "감시 1회 걸린 시간 (ms)"
          region  = var.region
          stat    = "Average"
          period  = var.canary_interval_minutes * 60
          metrics = [["CloudWatchSynthetics", "Duration", "CanaryName", local.canary_name]]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6
        properties = {
          title  = "ALB 오류 응답 수"
          region = var.region
          stat   = "Sum"
          period = 300
          metrics = [
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", data.aws_lb.monitor[0].arn_suffix, { label = "앱 5xx" }],
            ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", data.aws_lb.monitor[0].arn_suffix, { label = "ALB 5xx" }],
            ["AWS/ApplicationELB", "HTTPCode_Target_4XX_Count", "LoadBalancer", data.aws_lb.monitor[0].arn_suffix, { label = "앱 4xx" }]
          ]
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6
        properties = {
          title  = "ALB 응답 시간 (초)"
          region = var.region
          period = 300
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", data.aws_lb.monitor[0].arn_suffix, { stat = "p95", label = "p95" }],
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", data.aws_lb.monitor[0].arn_suffix, { stat = "Average", label = "평균" }]
          ]
        }
      }
    ]
  })
}

output "monitoring_dashboard" {
  description = "가용성 대시보드 이름 (CloudWatch > 대시보드)"
  value       = local.monitor ? aws_cloudwatch_dashboard.keeper[0].dashboard_name : null
}
