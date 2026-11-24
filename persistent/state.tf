# Terraform 상태 파일(state)을 보관하는 S3 버킷.
# 매일 destroy하는 infra/와 분리해 이 폴더(persistent/)에 둔다. 버킷이 infra/ 안에 있으면
# destroy할 때 상태 파일이 들어 있는 버킷까지 같이 지워진다.
#
# infra/의 state를 이 버킷으로 옮기는 방법은 infra/backend.tf.example 과 README의 "state를 S3로" 참고.
# 이 폴더 자신의 state는 로컬 파일로 두고 백업한다 (버킷을 만드는 쪽이 자기 버킷에 의존하지 않게 함).

locals {
  tfstate_bucket = "${var.name}-tfstate-${data.aws_caller_identity.this.account_id}"
}

resource "aws_s3_bucket" "tfstate" {
  bucket = local.tfstate_bucket

  lifecycle {
    prevent_destroy = true
  }
}

# 상태 파일 이전 버전을 남겨 실수로 덮어써도 되돌릴 수 있게 한다
resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# HTTPS가 아닌 접근은 거부
data "aws_iam_policy_document" "tfstate_tls_only" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.tfstate.arn, "${aws_s3_bucket.tfstate.arn}/*"]

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

resource "aws_s3_bucket_policy" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  policy = data.aws_iam_policy_document.tfstate_tls_only.json

  depends_on = [aws_s3_bucket_public_access_block.tfstate]
}
