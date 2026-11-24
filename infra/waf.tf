# ALB에 붙는 WAF. 연결은 Ingress annotation(wafv2-acl-arn)으로 합니다.
resource "aws_wafv2_web_acl" "keeper" {
  name  = "${var.project}-waf"
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  # 일반 웹 공격(XSS 등)
  rule {
    name     = "aws-common"
    priority = 1
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"
        # 요청 본문 8KB 제한 규칙은 서류 업로드를 막으므로 '기록만'으로 바꿈
        rule_action_override {
          name = "SizeRestrictions_BODY"
          action_to_use {
            count {}
          }
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "aws-common"
      sampled_requests_enabled   = true
    }
  }

  # SQL 인젝션
  rule {
    name     = "aws-sqli"
    priority = 2
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesSQLiRuleSet"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "aws-sqli"
      sampled_requests_enabled   = true
    }
  }

  # 대입 공격: IP당 5분에 300회 넘으면 차단 (시연 때 값 조정)
  rule {
    name     = "rate-limit"
    priority = 3
    # rate_limit_action=count 는 무중단 배포 측정(k6)처럼 요청이 많은 시험 동안만 쓰고, 끝나면 block으로 되돌린다
    action {
      dynamic "block" {
        for_each = var.rate_limit_action == "block" ? [1] : []
        content {}
      }
      dynamic "count" {
        for_each = var.rate_limit_action == "count" ? [1] : []
        content {}
      }
    }
    statement {
      rate_based_statement {
        limit              = 300
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-limit"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.project}-waf"
    sampled_requests_enabled   = true
  }
}

# WAF 로그: 어떤 요청을 차단·허용했는지 CloudWatch Logs에 남긴다 (RED 공격 시험의 탐지 확인용).
# 로그 그룹 이름은 반드시 aws-waf-logs- 로 시작해야 한다. destroy 때 같이 지워지므로 증적이 필요하면 지우기 전에 내보낸다.
resource "aws_cloudwatch_log_group" "waf" {
  name              = "aws-waf-logs-${var.project}"
  retention_in_days = 7
}

# WAF(delivery.logs 서비스)가 이 로그 그룹에 쓸 수 있게 하는 계정 단위 리소스 정책
data "aws_iam_policy_document" "waf_logs" {
  statement {
    sid       = "AllowWafLogDelivery"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.waf.arn}:*"]

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:*"]
    }
  }
}

resource "aws_cloudwatch_log_resource_policy" "waf" {
  policy_name     = "${var.project}-waf-logs"
  policy_document = data.aws_iam_policy_document.waf_logs.json
}

resource "aws_wafv2_web_acl_logging_configuration" "keeper" {
  resource_arn            = aws_wafv2_web_acl.keeper.arn
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]

  # 인증 정보·열람 토큰이 로그에 그대로 남지 않게 가린다
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
  redacted_fields {
    single_header {
      name = "x-view-token"
    }
  }

  depends_on = [aws_cloudwatch_log_resource_policy.waf]
}
