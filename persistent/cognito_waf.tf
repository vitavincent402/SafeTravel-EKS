# Cognito 로그인(호스팅 UI)용 WAF: 로그인 대입 공격을 IP당 요청 수로 막는다.
# ALB용 keeper-waf(infra/waf.tf)는 로그인을 보지 못한다. 로그인은 ALB가 아니라 Cognito 로그인 도메인에서 처리되기 때문이다.
# persistent/에 두는 이유: Cognito 풀이 persistent/에 있고, 매일 destroy해도 로그(aws-waf-logs-cognito)가 남아야
# SOC가 며칠치 Count 로그를 보고 Block 전환 여부를 정할 수 있다.
# 처음에는 Count(세기만 하고 막지 않음). SOC가 "정상 로그인이 한도에 걸린 기록 없음"을 확인한 뒤 cognito_rate_action=block.

variable "cognito_rate_limit" {
  description = "로그인 경로로 한 IP가 5분 동안 보낼 수 있는 요청 수(WAF 최소 10). Count 기간의 로그를 보고 조정"
  type        = number
  default     = 100

  validation {
    condition     = var.cognito_rate_limit >= 10
    error_message = "cognito_rate_limit은 10 이상이어야 합니다."
  }
}

variable "cognito_rate_action" {
  description = "rate-login 규칙의 동작. count(세기만) 또는 block. 처음에는 count"
  type        = string
  default     = "count"

  validation {
    condition     = contains(["count", "block"], var.cognito_rate_action)
    error_message = "cognito_rate_action은 count 또는 block이어야 합니다."
  }
}

resource "aws_wafv2_web_acl" "cognito" {
  name  = "${var.name}-cognito-waf"
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  # 로그인 화면(/login)과 토큰 발급(/oauth2/token) 요청이 한 IP에서 5분에 한도를 넘으면 동작(count|block)
  rule {
    name     = "rate-login"
    priority = 1

    action {
      dynamic "block" {
        for_each = var.cognito_rate_action == "block" ? [1] : []
        content {}
      }
      dynamic "count" {
        for_each = var.cognito_rate_action == "count" ? [1] : []
        content {}
      }
    }

    statement {
      rate_based_statement {
        limit              = var.cognito_rate_limit
        aggregate_key_type = "IP"

        scope_down_statement {
          or_statement {
            statement {
              byte_match_statement {
                search_string         = "/login"
                positional_constraint = "STARTS_WITH"
                field_to_match {
                  uri_path {}
                }
                text_transformation {
                  priority = 0
                  type     = "NONE"
                }
              }
            }
            statement {
              byte_match_statement {
                search_string         = "/oauth2/token"
                positional_constraint = "STARTS_WITH"
                field_to_match {
                  uri_path {}
                }
                text_transformation {
                  priority = 0
                  type     = "NONE"
                }
              }
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-login"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name}-cognito-waf"
    sampled_requests_enabled   = true
  }
}

resource "aws_wafv2_web_acl_association" "cognito" {
  resource_arn = aws_cognito_user_pool.users.arn
  web_acl_arn  = aws_wafv2_web_acl.cognito.arn
}

# 로그 그룹 이름은 반드시 aws-waf-logs- 로 시작해야 한다. SOC 읽기 역할(soc_reader.tf)이 이 이름으로 권한을 갖는다.
resource "aws_cloudwatch_log_group" "waf_cognito" {
  name              = "aws-waf-logs-cognito"
  retention_in_days = 7
}

data "aws_iam_policy_document" "waf_cognito_logs" {
  statement {
    sid       = "AllowWafLogDelivery"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.waf_cognito.arn}:*"]

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.this.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:logs:${var.region}:${data.aws_caller_identity.this.account_id}:*"]
    }
  }
}

resource "aws_cloudwatch_log_resource_policy" "waf_cognito" {
  policy_name     = "${var.name}-waf-cognito-logs"
  policy_document = data.aws_iam_policy_document.waf_cognito_logs.json
}

resource "aws_wafv2_web_acl_logging_configuration" "cognito" {
  resource_arn            = aws_wafv2_web_acl.cognito.arn
  log_destination_configs = [aws_cloudwatch_log_group.waf_cognito.arn]

  # 인증 정보가 로그에 그대로 남지 않게 가린다
  redacted_fields {
    single_header {
      name = "authorization"
    }
  }
  redacted_fields {
    single_header {
      name = "cookie"
    }
  }
  # 로그인 요청의 쿼리 문자열(client_id, redirect_uri, state, code_challenge 등)도 가린다 (SOC 요청, 11/25)
  redacted_fields {
    query_string {}
  }

  depends_on = [aws_cloudwatch_log_resource_policy.waf_cognito]
}

output "cognito_waf_web_acl_arn" {
  description = "Cognito 로그인용 WAF Web ACL"
  value       = aws_wafv2_web_acl.cognito.arn
}
