# 도메인을 쓰는 경우에만: ACM 인증서(HTTPS) + 앱 주소 레코드
locals {
  use_domain = var.domain_name != ""
}

data "aws_route53_zone" "this" {
  count = local.use_domain ? 1 : 0
  name  = var.hosted_zone_name
}

resource "aws_acm_certificate" "this" {
  count             = local.use_domain ? 1 : 0
  domain_name       = var.domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = local.use_domain ? {
    for o in aws_acm_certificate.this[0].domain_validation_options : o.domain_name => o
  } : {}

  zone_id         = data.aws_route53_zone.this[0].zone_id
  name            = each.value.resource_record_name
  type            = each.value.resource_record_type
  records         = [each.value.resource_record_value]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  count                   = local.use_domain ? 1 : 0
  certificate_arn         = aws_acm_certificate.this[0].arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# ALB는 배포 때 Load Balancer Controller가 만들기 때문에, 배포가 끝난 뒤 태그로 찾아 레코드를 겁니다.
data "aws_lb" "keeper" {
  count = local.use_domain && var.run_bootstrap_deploy ? 1 : 0
  tags = {
    "elbv2.k8s.aws/cluster" = module.eks.cluster_name
    "ingress.k8s.aws/stack" = "keeper" # Ingress의 group.name
  }
  depends_on = [terraform_data.bootstrap_deploy]
}

resource "aws_route53_record" "app" {
  count   = local.use_domain && var.run_bootstrap_deploy ? 1 : 0
  zone_id = data.aws_route53_zone.this[0].zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = data.aws_lb.keeper[0].dns_name
    zone_id                = data.aws_lb.keeper[0].zone_id
    evaluate_target_health = false
  }
}
