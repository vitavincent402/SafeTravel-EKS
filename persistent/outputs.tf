output "name_servers" {
  description = "도메인 등록 계정에서 이 4개로 도메인 이름 서버를 바꾼다"
  value       = aws_route53_zone.this.name_servers
}

output "hosted_zone_id" {
  value = aws_route53_zone.this.zone_id
}

output "cognito_user_pool_id" {
  description = "메인 스택 terraform.tfvars의 cognito_user_pool_id"
  value       = aws_cognito_user_pool.users.id
}

output "cognito_client_id" {
  description = "메인 스택 terraform.tfvars의 cognito_client_id"
  value       = aws_cognito_user_pool_client.web.id
}

output "cognito_login_domain" {
  description = "메인 스택 terraform.tfvars의 cognito_login_domain"
  value       = "https://${aws_cognito_user_pool_domain.login.domain}.auth.${var.region}.amazoncognito.com"
}

output "cognito_callback_urls" {
  value = local.callback_urls
}

output "cognito_logout_urls" {
  value = local.logout_urls
}

output "ses_dkim_records" {
  description = "자동으로 호스팅 영역에 들어간다. 확인용 출력"
  value = var.enable_ses_domain ? [
    for t in aws_sesv2_email_identity.domain[0].dkim_signing_attributes[0].tokens : "${t}._domainkey.${var.domain_name} -> ${t}.dkim.amazonses.com"
  ] : []
}

output "alert_topic_arn" {
  description = "메인 스택 terraform.tfvars의 alert_topic_arn (가용성 감시 알림 주제)"
  value       = aws_sns_topic.alerts.arn
}
