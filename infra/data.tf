# ---- KMS: 서류 봉투 암호화용 키 --------------------------------------------------
resource "aws_kms_key" "docs" {
  description             = "${var.project} document envelope encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_kms_alias" "docs" {
  name          = "alias/${var.project}-docs"
  target_key_id = aws_kms_key.docs.key_id
}

# ---- S3: 서류 암호문 저장 -------------------------------------------------------
resource "aws_s3_bucket" "docs" {
  bucket_prefix = "${var.project}-docs-"
  force_destroy = true # destroy 때 안에 파일이 있어도 삭제
}

resource "aws_s3_bucket_public_access_block" "docs" {
  bucket                  = aws_s3_bucket.docs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "docs" {
  bucket = aws_s3_bucket.docs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.docs.arn
    }
    bucket_key_enabled = true
  }
}

# HTTPS가 아닌 요청 거부
resource "aws_s3_bucket_policy" "docs" {
  bucket = aws_s3_bucket.docs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.docs.arn, "${aws_s3_bucket.docs.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
  depends_on = [aws_s3_bucket_public_access_block.docs]
}

# ---- RDS --------------------------------------------------------------------------
resource "aws_security_group" "rds" {
  name        = "${var.project}-rds"
  description = "RDS: EKS nodes only"
  vpc_id      = module.vpc.vpc_id
}

# 노드 그룹에서 오는 DB 포트만 허용. 파드 단위 구분은 NetworkPolicy가 담당합니다.
resource "aws_vpc_security_group_ingress_rule" "rds_from_nodes" {
  security_group_id            = aws_security_group.rds.id
  referenced_security_group_id = module.eks.node_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_db_instance" "keeper" {
  identifier     = "${var.project}-db"
  engine         = "postgres"
  engine_version = "16"
  instance_class = "db.t3.micro"

  allocated_storage = 20
  storage_encrypted = true
  kms_key_id        = aws_kms_key.docs.arn

  db_name  = "keeper"
  username = "keeper"
  # 비밀번호는 RDS가 Secrets Manager에 직접 만들고 관리합니다 (Terraform 상태·Git에 남지 않음).
  manage_master_user_password = true

  db_subnet_group_name   = module.vpc.database_subnet_group_name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  multi_az               = false

  skip_final_snapshot = true
  deletion_protection = false
  apply_immediately   = true

  # SOC 감시용 로그 (observability.tf, enable_observability_logs). 꺼져 있으면 기본값 그대로
  parameter_group_name            = local.obs_enabled ? aws_db_parameter_group.keeper[0].name : null
  enabled_cloudwatch_logs_exports = local.obs_enabled ? ["postgresql"] : []
  depends_on                      = [aws_cloudwatch_log_group.rds]
}

# ---- Secrets Manager: 앱 비밀값 (토큰 서명 키) -------------------------------------
resource "random_password" "token_signing_key" {
  length  = 48
  special = false
}

resource "aws_secretsmanager_secret" "app" {
  name                    = "${var.project}/app"
  recovery_window_in_days = 0 # 다음 구축 때 같은 이름을 바로 다시 쓰기 위해
}

resource "aws_secretsmanager_secret_version" "app" {
  secret_id     = aws_secretsmanager_secret.app.id
  secret_string = jsonencode({ token_signing_key = random_password.token_signing_key.result })
}
