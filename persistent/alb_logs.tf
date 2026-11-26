# ALB 접속 로그를 쌓는 S3 버킷 (SOC 요청, 11/25).
# persistent/에 두는 이유: infra/는 매일 destroy되지만 이 버킷은 남아야 SOC가 이어서 읽을 수 있다.
# ALB가 쓰는 로그는 SSE-S3(AES256)만 지원한다(SSE-KMS 불가). 보존 3일, 공개 차단, HTTPS 강제.
# 로그에는 요청 경로와 쿼리 문자열이 들어간다(WAF 로그처럼 가릴 수 없다). SOC 수집기가 읽자마자 쿼리 문자열을 버린다.
# 켜는 쪽은 infra/ (enable_alb_access_logs=true → Ingress 속성). 버킷이 먼저 있어야 ALB 생성이 실패하지 않는다.
locals {
  alb_log_bucket = "${var.name}-alb-logs-${data.aws_caller_identity.this.account_id}"
}

# 리전별 ELB 로그 전달 계정(서울 등)을 AWS가 알려 준다
data "aws_elb_service_account" "main" {}

resource "aws_s3_bucket" "alb_logs" {
  bucket = local.alb_log_bucket
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket                  = aws_s3_bucket.alb_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  rule {
    id     = "expire-3d"
    status = "Enabled"
    filter {}
    expiration {
      days = 3
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

data "aws_iam_policy_document" "alb_logs" {
  statement {
    sid       = "AllowAlbLogDelivery"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.alb_logs.arn}/alb/AWSLogs/${data.aws_caller_identity.this.account_id}/*"]
    principals {
      type        = "AWS"
      identifiers = [data.aws_elb_service_account.main.arn]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.alb_logs.arn, "${aws_s3_bucket.alb_logs.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "alb_logs" {
  bucket     = aws_s3_bucket.alb_logs.id
  policy     = data.aws_iam_policy_document.alb_logs.json
  depends_on = [aws_s3_bucket_public_access_block.alb_logs]
}

output "alb_log_bucket" {
  description = "ALB 접속 로그 버킷 이름 (infra에서 enable_alb_access_logs=true로 켠다)"
  value       = aws_s3_bucket.alb_logs.bucket
}
