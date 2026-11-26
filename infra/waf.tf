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
        # 서류 업로드(POST /api/docs)는 본문이 base64로 인코딩된 큰 파일이라 XSS 본문 검사에 오탐이 난다(11/25 11:20, 3.4MB 업로드 4건 403).
        # 이 규칙은 '기록만'으로 바꾸고, 업로드 경로만 뺀 같은 검사를 아래 xss-body-except-docs 규칙으로 따로 건다.
        rule_action_override {
          name = "CrossSiteScripting_BODY"
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

  # 요청 본문의 XSS 검사: 서류 업로드 경로(/api/docs)만 빼고 모든 경로에 적용 (위 aws-common의 본문 XSS 규칙을 대신함)
  rule {
    name     = "xss-body-except-docs"
    priority = 4
    action {
      block {}
    }
    statement {
      and_statement {
        statement {
          xss_match_statement {
            field_to_match {
              body {
                oversize_handling = "CONTINUE"
              }
            }
            text_transformation {
              priority = 0
              type     = "NONE"
            }
            text_transformation {
              priority = 1
              type     = "URL_DECODE"
            }
            text_transformation {
              priority = 2
              type     = "HTML_ENTITY_DECODE"
            }
          }
        }
        statement {
          not_statement {
            statement {
              byte_match_statement {
                search_string         = "/api/docs"
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
      metric_name                = "xss-body-except-docs"
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

  # 대입 공격: IP당 5분에 var.rate_limit(기본 1000)회 넘으면 차단.
  # 화면이 5초마다 폴링하고(요청 2~3개) 공용망은 여러 명이 한 IP라서, 300으로는 정상 사용도 걸렸다(11/25 보호자 시험)
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
        limit              = var.rate_limit
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-limit"
      sampled_requests_enabled   = true
    }
  }

  # ---- 2.5차(SafeTravel-Serverless 기술 문서 7장)에서 가져온 추가 규칙 5개 ----
  # 처음에는 Count(waf_extra_rules_action)로 넣어 로그를 보고, 정상 요청이 걸리지 않는지 확인한 뒤 block으로 바꾼다.
  # 새 규칙은 오탐이 날 수 있다(11/25 업로드 XMP 사례). WAF 로그에서 이 규칙 이름으로 걸린 요청을 먼저 확인한다.

  # TRACE·CONNECT 메서드 차단
  rule {
    name     = "blocked-method"
    priority = 5
    action {
      dynamic "block" {
        for_each = var.waf_extra_rules_action == "block" ? [1] : []
        content {}
      }
      dynamic "count" {
        for_each = var.waf_extra_rules_action == "count" ? [1] : []
        content {}
      }
    }
    statement {
      or_statement {
        statement {
          byte_match_statement {
            search_string         = "TRACE"
            positional_constraint = "EXACTLY"
            field_to_match {
              method {}
            }
            text_transformation {
              priority = 0
              type     = "NONE"
            }
          }
        }
        statement {
          byte_match_statement {
            search_string         = "CONNECT"
            positional_constraint = "EXACTLY"
            field_to_match {
              method {}
            }
            text_transformation {
              priority = 0
              type     = "NONE"
            }
          }
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "blocked-method"
      sampled_requests_enabled   = true
    }
  }

  # 민감 경로 탐색 차단: /.git, /.env는 경로 어디에 있어도(포함 일치), /phpmyadmin은 경로 시작.
  # 2.5차에서 시작 일치로 두었다가 /anything/.env를 놓쳐 포함 일치로 고친 사례(11/17)를 처음부터 반영. 경로는 URL 디코딩 후 소문자로 비교한다.
  rule {
    name     = "blocked-path"
    priority = 6
    action {
      dynamic "block" {
        for_each = var.waf_extra_rules_action == "block" ? [1] : []
        content {}
      }
      dynamic "count" {
        for_each = var.waf_extra_rules_action == "count" ? [1] : []
        content {}
      }
    }
    statement {
      or_statement {
        statement {
          byte_match_statement {
            search_string         = "/.git"
            positional_constraint = "CONTAINS"
            field_to_match {
              uri_path {}
            }
            text_transformation {
              priority = 0
              type     = "URL_DECODE"
            }
            text_transformation {
              priority = 1
              type     = "LOWERCASE"
            }
          }
        }
        statement {
          byte_match_statement {
            search_string         = "/.env"
            positional_constraint = "CONTAINS"
            field_to_match {
              uri_path {}
            }
            text_transformation {
              priority = 0
              type     = "URL_DECODE"
            }
            text_transformation {
              priority = 1
              type     = "LOWERCASE"
            }
          }
        }
        statement {
          byte_match_statement {
            search_string         = "/phpmyadmin"
            positional_constraint = "STARTS_WITH"
            field_to_match {
              uri_path {}
            }
            text_transformation {
              priority = 0
              type     = "URL_DECODE"
            }
            text_transformation {
              priority = 1
              type     = "LOWERCASE"
            }
          }
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "blocked-path"
      sampled_requests_enabled   = true
    }
  }

  # 이중 인코딩(%25) 경로 요청 차단. 정상 요청에는 거의 없지만 파일 이름에 %가 들어가는 경우 오탐이 날 수 있으니 Count 로그로 확인한다
  rule {
    name     = "nested-encoding"
    priority = 7
    action {
      dynamic "block" {
        for_each = var.waf_extra_rules_action == "block" ? [1] : []
        content {}
      }
      dynamic "count" {
        for_each = var.waf_extra_rules_action == "count" ? [1] : []
        content {}
      }
    }
    statement {
      byte_match_statement {
        search_string         = "%25"
        positional_constraint = "CONTAINS"
        field_to_match {
          uri_path {}
        }
        text_transformation {
          priority = 0
          type     = "NONE"
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "nested-encoding"
      sampled_requests_enabled   = true
    }
  }

  # AWS 관리형: 알려진 악성 입력(Log4j 등). 관리형 그룹은 Count로 둘 때 override_action을 count로 한다
  rule {
    name     = "aws-known-bad-inputs"
    priority = 8
    override_action {
      dynamic "none" {
        for_each = var.waf_extra_rules_action == "block" ? [1] : []
        content {}
      }
      dynamic "count" {
        for_each = var.waf_extra_rules_action == "count" ? [1] : []
        content {}
      }
    }
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "aws-known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  # AWS 관리형: IP 평판 목록(악성 IP)
  rule {
    name     = "aws-ip-reputation"
    priority = 9
    override_action {
      dynamic "none" {
        for_each = var.waf_extra_rules_action == "block" ? [1] : []
        content {}
      }
      dynamic "count" {
        for_each = var.waf_extra_rules_action == "count" ? [1] : []
        content {}
      }
    }
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesAmazonIpReputationList"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "aws-ip-reputation"
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
  # 로그인 후 돌아오는 요청의 쿼리(인증 코드 code 등)가 로그에 남지 않게 가린다 (SOC 요청, 11/25)
  redacted_fields {
    query_string {}
  }

  depends_on = [aws_cloudwatch_log_resource_policy.waf]
}
