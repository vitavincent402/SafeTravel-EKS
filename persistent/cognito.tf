# Cognito 사용자 풀 (회원가입·로그인·잠금·비밀번호 재설정). 2.5차 cognito.tf를 3차용으로 줄인 것:
# Lambda 사전 가입 검사와 2.5차 전용 조회(data) 의존은 뺐고, 삭제 보호를 켰다.
# 주의: schema(email, name)는 만든 뒤 바꾸면 풀이 새로 만들어진다(회원 정보 사라짐). 처음부터 정확히 둔다.

resource "aws_cognito_user_pool" "users" {
  name = "${var.name}-users"

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]
  username_configuration {
    case_sensitive = false
  }

  password_policy {
    minimum_length                   = 8
    require_lowercase                = true
    require_uppercase                = false
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = 1
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  schema {
    name                = "email"
    attribute_data_type = "String"
    required            = true
    mutable             = true
    string_attribute_constraints {
      min_length = 5
      max_length = 254
    }
  }

  schema {
    name                = "name"
    attribute_data_type = "String"
    required            = true
    mutable             = true
    string_attribute_constraints {
      min_length = 1
      max_length = 50
    }
  }

  verification_message_template {
    default_email_option = "CONFIRM_WITH_CODE"
    email_subject        = "[SafeTravel] 이메일 인증 코드"
    email_message        = "SafeTravel 인증 코드는 {####} 입니다."
  }

  admin_create_user_config {
    allow_admin_create_user_only = false
  }

  email_configuration {
    email_sending_account = var.cognito_use_ses ? "DEVELOPER" : "COGNITO_DEFAULT"
    source_arn            = var.cognito_use_ses ? aws_sesv2_email_identity.domain[0].arn : null
    from_email_address    = var.cognito_use_ses ? "no-reply@${var.domain_name}" : null
  }

  # 콘솔·CLI에서 실수로 지우는 것을 막는다. 정말 지울 때는 "INACTIVE"로 바꿔 apply한 뒤 삭제한다.
  deletion_protection = "ACTIVE"

  lifecycle {
    prevent_destroy = true

    precondition {
      condition     = !var.cognito_use_ses || var.enable_ses_domain
      error_message = "cognito_use_ses = true 이려면 enable_ses_domain = true 여야 합니다."
    }
  }
}

# 관리자 그룹 (관리자 Q&A 답변 등)
resource "aws_cognito_user_group" "admin" {
  user_pool_id = aws_cognito_user_pool.users.id
  name         = "admin"
  description  = "관리자 그룹"
}

locals {
  callback_urls = distinct(concat(
    flatten([for h in var.web_hosts : [for p in var.callback_paths : "https://${h}${p}"]]),
    var.extra_callback_urls,
  ))
  logout_urls = distinct(concat(
    flatten([for h in var.web_hosts : [for p in var.logout_paths : "https://${h}${p}"]]),
    var.extra_logout_urls,
  ))
}

# 화면(브라우저)용 앱 클라이언트: 비밀키 없음, 인증 코드 + PKCE
resource "aws_cognito_user_pool_client" "web" {
  name         = "${var.name}-web"
  user_pool_id = aws_cognito_user_pool.users.id

  generate_secret                      = false
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  supported_identity_providers         = ["COGNITO"]
  callback_urls                        = local.callback_urls
  logout_urls                          = local.logout_urls

  explicit_auth_flows = ["ALLOW_REFRESH_TOKEN_AUTH", "ALLOW_USER_SRP_AUTH"]

  access_token_validity  = 10
  id_token_validity      = 10
  refresh_token_validity = 60
  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "minutes"
  }

  prevent_user_existence_errors = "ENABLED"
  enable_token_revocation       = true
}

# 관리형 로그인 페이지 주소 (https://<prefix>.auth.<리전>.amazoncognito.com)
resource "aws_cognito_user_pool_domain" "login" {
  domain                = "${var.name}-login-${substr(data.aws_caller_identity.this.account_id, 8, 4)}"
  user_pool_id          = aws_cognito_user_pool.users.id
  managed_login_version = var.cognito_managed_login_version
}
