# SES 도메인 ID (Easy DKIM). 이름 서버가 이 영역을 가리켜야 DKIM이 확인(Verified)된다.
resource "aws_sesv2_email_identity" "domain" {
  count          = var.enable_ses_domain ? 1 : 0
  email_identity = var.domain_name

  dkim_signing_attributes {
    next_signing_key_length = "RSA_2048_BIT"
  }

  lifecycle {
    prevent_destroy = true
  }
}

# DKIM 토큰은 SES ID를 만들 때마다 새로 생긴다. 예전 영역에서 옮긴 CNAME은 쓸 수 없고, 이 레코드가 정답이다.
resource "aws_route53_record" "dkim" {
  count           = var.enable_ses_domain ? 3 : 0
  zone_id         = aws_route53_zone.this.zone_id
  name            = "${aws_sesv2_email_identity.domain[0].dkim_signing_attributes[0].tokens[count.index]}._domainkey.${var.domain_name}"
  type            = "CNAME"
  ttl             = 600
  records         = ["${aws_sesv2_email_identity.domain[0].dkim_signing_attributes[0].tokens[count.index]}.dkim.amazonses.com"]
  allow_overwrite = true
}
