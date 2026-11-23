# 이미지 3개 + Helm 차트 패키지 1개
locals {
  ecr_repositories = ["keeper/web", "keeper/api", "keeper/vault", "charts/keeper"]
}

resource "aws_ecr_repository" "this" {
  for_each = toset(local.ecr_repositories)

  name                 = each.value
  image_tag_mutability = "IMMUTABLE" # 같은 태그로 덮어쓰기 금지
  force_delete         = true        # destroy 때 이미지가 있어도 삭제

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
  }
}

data "aws_caller_identity" "current" {}

locals {
  ecr_registry = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
}
