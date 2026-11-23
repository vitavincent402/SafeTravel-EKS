# ===================================================================================
# apply 마지막 단계: 배포 값을 GitHub 저장소 변수로 넘기고, 배포 파이프라인을 실행한 뒤 끝날 때까지 기다림
# → terraform apply 한 번이 끝나면 앱까지 떠 있는 상태
# 필요: 실행하는 PC에 gh(로그인 상태), aws CLI, helm. Windows는 PowerShell, 그 외는 bash로 실행
# ===================================================================================
locals {
  # Windows(PowerShell)에서 실행하는지: 경로가 "C:/..." 형태면 Windows
  is_windows = substr(abspath(path.root), 1, 1) == ":"

  helm_values = yamlencode({
    aws = {
      region         = var.region
      documentBucket = aws_s3_bucket.docs.bucket
      kmsKeyArn      = aws_kms_key.docs.arn
      dbSecretArn    = aws_db_instance.keeper.master_user_secret[0].secret_arn
      appSecretArn   = aws_secretsmanager_secret.app.arn
      dbHost         = aws_db_instance.keeper.address
      dbName         = aws_db_instance.keeper.db_name
    }
    serviceAccounts = {
      api   = { roleArn = aws_iam_role.api.arn }
      vault = { roleArn = aws_iam_role.vault.arn }
    }
    ingress = {
      host           = var.domain_name
      certificateArn = local.use_domain ? aws_acm_certificate_validation.this[0].certificate_arn : ""
      wafAclArn      = aws_wafv2_web_acl.keeper.arn
    }
    networkPolicy = {
      albSourceCidrs = local.public_subnets
      databaseCidrs  = local.database_subnets
    }
  })

  github_vars = {
    AWS_REGION          = var.region
    AWS_DEPLOY_ROLE_ARN = aws_iam_role.github_actions.arn
    EKS_CLUSTER_NAME    = module.eks.cluster_name
    ECR_REGISTRY        = local.ecr_registry
  }
}

# 파이프라인 실행 스크립트: 실행하는 PC에 맞춰 bash 또는 PowerShell 버전을 씀
locals {
  deploy_bash = <<-EOT
    set -euo pipefail
    # 1) 배포에 필요한 값을 저장소 변수로 (ARN 같은 비밀이 아닌 값만)
    echo "$GH_VARS" | python3 -c 'import json,sys;[print(k+"="+v) for k,v in json.load(sys.stdin).items()]' |
      while IFS='=' read -r k v; do gh variable set "$k" --repo "$REPO" --body "$v"; done
    printf '%s' "$HELM_VALUES" | gh variable set KEEPER_HELM_VALUES --repo "$REPO"

    # 2) 파이프라인 실행 후, 새로 생긴 실행을 찾아 끝날 때까지 대기
    before=$(gh run list --repo "$REPO" --workflow deploy.yml --limit 1 --json databaseId -q '.[0].databaseId' || true)
    gh workflow run deploy.yml --repo "$REPO" --ref main
    for i in $(seq 1 30); do
      sleep 5
      run=$(gh run list --repo "$REPO" --workflow deploy.yml --limit 1 --json databaseId -q '.[0].databaseId')
      [ -n "$run" ] && [ "$run" != "$before" ] && break
    done
    echo "watching run $run"
    gh run watch "$run" --repo "$REPO" --exit-status
  EOT

  deploy_ps = <<-EOT
    $ErrorActionPreference = "Stop"
    # 1) 배포에 필요한 값을 저장소 변수로 (ARN 같은 비밀이 아닌 값만)
    $vars = $env:GH_VARS | ConvertFrom-Json
    foreach ($p in $vars.PSObject.Properties) {
      gh variable set $p.Name --repo $env:REPO --body $p.Value
      if ($LASTEXITCODE -ne 0) { exit 1 }
    }
    $env:HELM_VALUES | gh variable set KEEPER_HELM_VALUES --repo $env:REPO
    if ($LASTEXITCODE -ne 0) { exit 1 }

    # 2) 파이프라인 실행 후, 새로 생긴 실행을 찾아 끝날 때까지 대기
    $before = gh run list --repo $env:REPO --workflow deploy.yml --limit 1 --json databaseId -q '.[0].databaseId'
    gh workflow run deploy.yml --repo $env:REPO --ref main
    if ($LASTEXITCODE -ne 0) { exit 1 }
    $run = ""
    for ($i = 0; $i -lt 30; $i++) {
      Start-Sleep -Seconds 5
      $run = gh run list --repo $env:REPO --workflow deploy.yml --limit 1 --json databaseId -q '.[0].databaseId'
      if ($run -and $run -ne $before) { break }
    }
    Write-Output "watching run $run"
    gh run watch $run --repo $env:REPO --exit-status
    exit $LASTEXITCODE
  EOT
}

resource "terraform_data" "bootstrap_deploy" {
  count = var.run_bootstrap_deploy ? 1 : 0

  # 값이 바뀌면 다시 실행 (클러스터를 새로 만들면 다시 배포)
  triggers_replace = [module.eks.cluster_arn, sha256(local.helm_values)]

  provisioner "local-exec" {
    interpreter = local.is_windows ? ["PowerShell", "-Command"] : ["bash", "-c"]
    environment = {
      REPO        = var.github_repo
      HELM_VALUES = local.helm_values
      GH_VARS     = jsonencode(local.github_vars)
    }
    command = local.is_windows ? local.deploy_ps : local.deploy_bash
  }

  depends_on = [
    helm_release.lbc,
    kubernetes_namespace.keeper,
    aws_iam_role_policy.github_actions,
    aws_ecr_repository.this,
    aws_db_instance.keeper,
  ]
}

# destroy 때 가장 먼저 앱을 지워서, Load Balancer Controller가 ALB를 정리하게 함
# (ALB는 Terraform이 만든 게 아니라서 남아 있으면 VPC 삭제가 멈춤)
resource "terraform_data" "app_cleanup" {
  # input이 바뀌어도 교체되지 않고 값만 갱신됨 (destroy 때는 마지막 apply의 값을 씀)
  input = {
    cluster = module.eks.cluster_name
    region  = var.region
    windows = local.is_windows
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = self.input.windows ? ["PowerShell", "-Command"] : ["bash", "-c"]
    command = self.input.windows ? join("\n", [
      "$env:KUBECONFIG = [System.IO.Path]::GetTempFileName()",
      "aws eks update-kubeconfig --name ${self.input.cluster} --region ${self.input.region} | Out-Null",
      "helm uninstall keeper -n keeper --wait --timeout 5m",
      "Write-Output 'waiting for ALB cleanup'; Start-Sleep -Seconds 60",
      "exit 0",
      ]) : join("\n", [
      "set -u",
      "export KUBECONFIG=$(mktemp)",
      "aws eks update-kubeconfig --name '${self.input.cluster}' --region '${self.input.region}' >/dev/null",
      "helm uninstall keeper -n keeper --wait --timeout 5m || true",
      "echo 'waiting for ALB cleanup'; sleep 60",
    ])
  }

  # 이 리소스가 LB Controller·네임스페이스보다 먼저 삭제되도록 의존 관계를 둠
  depends_on = [helm_release.lbc, kubernetes_namespace.keeper]
}
