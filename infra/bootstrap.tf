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
    cognito = {
      userPoolId  = var.cognito_user_pool_id
      clientId    = var.cognito_client_id
      loginDomain = var.cognito_login_domain
    }
    ingress = {
      hosts          = local.all_domains
      certificateArn = local.use_domain ? aws_acm_certificate_validation.this[0].certificate_arn : ""
      wafAclArn      = var.hardening ? aws_wafv2_web_acl.keeper.arn : ""
      # ALB 접속 로그 버킷(persistent/ alb_logs.tf). 비우면 로그를 켜지 않음
      accessLogBucket = var.enable_alb_access_logs ? "${var.project}-alb-logs-${data.aws_caller_identity.current.account_id}" : ""
    }
    networkPolicy = {
      enabled        = var.hardening
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
    helm_release.security_baseline, # 입장 정책이 먼저 걸린 상태에서 앱을 배포
    aws_iam_role_policy.github_actions,
    aws_ecr_repository.this,
    aws_db_instance.keeper,
  ]
}

# destroy 때 가장 먼저 앱을 지우고, Load Balancer Controller가 만든 ALB·대상 그룹·보안 그룹이 실제로 사라졌는지 확인함
# (이 리소스들은 Terraform이 만든 게 아니라서 남아 있으면 VPC·서브넷·WAF 삭제가 멈춤)
#   1) helm uninstall
#   2) 최대 5분 동안 ALB·대상 그룹·보안 그룹이 사라지기를 기다림
#   3) 남아 있으면 강제 정리: Ingress·TargetGroupBinding 종료 표시 제거 → ALB 삭제 → 대상 그룹 삭제
#      → 노드 보안 그룹에 컨트롤러가 넣은 규칙 제거 → 보안 그룹 삭제 (각 단계 최대 5분 재시도)
#   4) 그래도 남으면 exit 1로 destroy를 멈춤 (컨트롤러가 지워지기 전에 사람이 보게 함)
# destroy 시점에는 self만 참조할 수 있어서 스크립트와 값을 input에 넣어 둠.
# input은 apply 때 갱신되므로, 이 스크립트를 고쳤다면 apply를 한 번 거쳐야 destroy에 반영됨.
# ALB·대상 그룹은 이 VPC 안에 있는 것 전부를, 보안 그룹은 컨트롤러 태그(elbv2.k8s.aws/cluster=클러스터 이름)가 붙은 것만 대상으로 함.
resource "terraform_data" "app_cleanup" {
  input = {
    cluster = module.eks.cluster_name
    region  = var.region
    vpc_id  = module.vpc.vpc_id
    windows = local.is_windows

    script_ps = <<-EOT
      $ErrorActionPreference = "Continue"
      $cluster = $env:CLUSTER
      $region  = $env:REGION
      $vpc     = $env:VPC_ID
      $tagKey  = "elbv2.k8s.aws/cluster"

      $env:KUBECONFIG = Join-Path $env:TEMP ("keeper-kc-" + [guid]::NewGuid().ToString())
      aws eks update-kubeconfig --name $cluster --region $region 2>&1 | Out-Null
      $kubeOk = ($LASTEXITCODE -eq 0)
      if (-not $kubeOk) { Write-Output "WARN: cannot reach cluster (kubeconfig). skip helm uninstall." }

      # 1) remove the app
      if ($kubeOk) {
        helm uninstall keeper -n keeper --wait --timeout 5m
        if ($LASTEXITCODE -ne 0) { Write-Output "WARN: helm uninstall exit $LASTEXITCODE (release missing or timed out)" }
      }

      # leftovers: a failed aws call counts as "ERR" so it is never mistaken for clean
      function Get-Words($text) { @(($text -join " ") -split "\s+" | Where-Object { $_ -and $_ -ne "None" }) }
      function Get-LeftLb {
        $o = aws elbv2 describe-load-balancers --region $region --query "LoadBalancers[?VpcId=='$vpc'].LoadBalancerArn" --output text 2>$null
        if ($LASTEXITCODE -ne 0) { return @("ERR") }
        return @(Get-Words $o)
      }
      function Get-LeftTg {
        $o = aws elbv2 describe-target-groups --region $region --query "TargetGroups[?VpcId=='$vpc'].TargetGroupArn" --output text 2>$null
        if ($LASTEXITCODE -ne 0) { return @("ERR") }
        return @(Get-Words $o)
      }
      function Get-LeftSg {
        $o = aws ec2 describe-security-groups --region $region --filters "Name=tag:$tagKey,Values=$cluster" --query "SecurityGroups[].GroupId" --output text 2>$null
        if ($LASTEXITCODE -ne 0) { return @("ERR") }
        return @(Get-Words $o)
      }
      function Get-Left { return @(@(Get-LeftLb) + @(Get-LeftTg) + @(Get-LeftSg)) }

      # 2) wait up to 5 minutes for the controller to remove them
      $deadline = (Get-Date).AddMinutes(5)
      while ($true) {
        $left = @(Get-Left)
        if ($left.Count -eq 0) { Write-Output "ALB cleanup done"; exit 0 }
        if ((Get-Date) -gt $deadline) { break }
        Write-Output ("waiting: " + $left.Count + " leftover (ALB/target group/security group)")
        Start-Sleep -Seconds 10
      }

      # 3) forced cleanup
      Write-Output "WARN: leftovers after wait. forcing cleanup."
      if ($kubeOk) {
        $f = Join-Path $env:TEMP "nofin.json"
        (@{ metadata = @{ finalizers = $null } } | ConvertTo-Json -Compress) | Out-File -Encoding ascii $f
        foreach ($kind in @("ingress", "targetgroupbindings")) {
          $names = kubectl get $kind -n keeper -o name 2>$null
          foreach ($n in $names) { kubectl patch $n -n keeper --type=merge --patch-file $f }
        }
      }
      foreach ($arn in @(Get-LeftLb)) {
        if ($arn -ne "ERR") { aws elbv2 delete-load-balancer --region $region --load-balancer-arn $arn 2>&1 | Out-Null }
      }
      $deadline = (Get-Date).AddMinutes(5)
      while ((@(Get-LeftLb)).Count -gt 0 -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 10 }

      $deadline = (Get-Date).AddMinutes(5)
      while ($true) {
        foreach ($arn in @(Get-LeftTg)) {
          if ($arn -ne "ERR") { aws elbv2 delete-target-group --region $region --target-group-arn $arn 2>&1 | Out-Null }
        }
        foreach ($sg in @(Get-LeftSg)) {
          if ($sg -eq "ERR") { continue }
          # remove rules in other security groups that reference this one (the controller adds one to the node security group)
          $holders = aws ec2 describe-security-groups --region $region --filters "Name=ip-permission.group-id,Values=$sg" --query "SecurityGroups[].GroupId" --output text 2>$null
          foreach ($holder in @(Get-Words $holders)) {
            $j = (aws ec2 describe-security-group-rules --region $region --filters "Name=group-id,Values=$holder" --output json 2>$null) -join ""
            if (-not $j) { continue }
            $rules = (ConvertFrom-Json $j).SecurityGroupRules | Where-Object { (-not $_.IsEgress) -and ($_.ReferencedGroupInfo.GroupId -eq $sg) }
            foreach ($rule in @($rules)) {
              aws ec2 revoke-security-group-ingress --region $region --group-id $holder --security-group-rule-ids $rule.SecurityGroupRuleId 2>&1 | Out-Null
            }
          }
          aws ec2 delete-security-group --region $region --group-id $sg 2>&1 | Out-Null
        }
        if ((@(Get-Left)).Count -eq 0) { break }
        if ((Get-Date) -gt $deadline) { break }
        Start-Sleep -Seconds 10
      }

      # 4) still there: stop destroy so a person can look before the controller is removed
      $left = @(Get-Left)
      if ($left.Count -eq 0) { Write-Output "forced cleanup done"; exit 0 }
      Write-Output ("ERROR: leftovers remain: " + ($left -join ", "))
      Write-Output "Remove them (or fix the cause), then run terraform destroy again."
      exit 1
    EOT

    script_sh = <<-EOT
      set -u
      CLUSTER_TAG_KEY="elbv2.k8s.aws/cluster"
      export KUBECONFIG="$(mktemp)"
      KUBE_OK=0
      aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" >/dev/null 2>&1 && KUBE_OK=1
      [ "$KUBE_OK" = 1 ] || echo "WARN: cannot reach cluster (kubeconfig). skip helm uninstall."

      # 1) remove the app
      if [ "$KUBE_OK" = 1 ]; then
        helm uninstall keeper -n keeper --wait --timeout 5m || echo "WARN: helm uninstall failed (release missing or timed out)"
      fi

      # leftovers: a failed aws call counts as "ERR" so it is never mistaken for clean
      words() { tr -s '[:space:]' '\n' | grep -v '^$' | grep -v '^None$'; }
      left_lb() {
        o=$(aws elbv2 describe-load-balancers --region "$REGION" --query "LoadBalancers[?VpcId=='$VPC_ID'].LoadBalancerArn" --output text 2>/dev/null) || { echo ERR; return; }
        echo "$o" | words
      }
      left_tg() {
        o=$(aws elbv2 describe-target-groups --region "$REGION" --query "TargetGroups[?VpcId=='$VPC_ID'].TargetGroupArn" --output text 2>/dev/null) || { echo ERR; return; }
        echo "$o" | words
      }
      left_sg() {
        o=$(aws ec2 describe-security-groups --region "$REGION" --filters "Name=tag:$CLUSTER_TAG_KEY,Values=$CLUSTER" --query "SecurityGroups[].GroupId" --output text 2>/dev/null) || { echo ERR; return; }
        echo "$o" | words
      }
      left_all() { left_lb; left_tg; left_sg; }
      count_left() { left_all | wc -l | tr -d ' '; }

      # 2) wait up to 5 minutes for the controller to remove them
      end=$(( $(date +%s) + 300 ))
      while :; do
        n=$(count_left)
        if [ "$n" = 0 ]; then echo "ALB cleanup done"; exit 0; fi
        [ "$(date +%s)" -gt "$end" ] && break
        echo "waiting: $n leftover (ALB/target group/security group)"
        sleep 10
      done

      # 3) forced cleanup
      echo "WARN: leftovers after wait. forcing cleanup."
      if [ "$KUBE_OK" = 1 ]; then
        for kind in ingress targetgroupbindings; do
          for n in $(kubectl get "$kind" -n keeper -o name 2>/dev/null); do
            kubectl patch "$n" -n keeper --type=merge -p '{"metadata":{"finalizers":null}}'
          done
        done
      fi
      for arn in $(left_lb); do
        [ "$arn" = ERR ] || aws elbv2 delete-load-balancer --region "$REGION" --load-balancer-arn "$arn" >/dev/null 2>&1
      done
      end=$(( $(date +%s) + 300 ))
      while [ -n "$(left_lb)" ] && [ "$(date +%s)" -lt "$end" ]; do sleep 10; done

      end=$(( $(date +%s) + 300 ))
      while :; do
        for arn in $(left_tg); do
          [ "$arn" = ERR ] || aws elbv2 delete-target-group --region "$REGION" --target-group-arn "$arn" >/dev/null 2>&1
        done
        for sg in $(left_sg); do
          [ "$sg" = ERR ] && continue
          # remove rules in other security groups that reference this one (the controller adds one to the node security group)
          for holder in $(aws ec2 describe-security-groups --region "$REGION" --filters "Name=ip-permission.group-id,Values=$sg" --query "SecurityGroups[].GroupId" --output text 2>/dev/null); do
            for rid in $(aws ec2 describe-security-group-rules --region "$REGION" --filters "Name=group-id,Values=$holder" --query "SecurityGroupRules[?IsEgress==\`false\` && ReferencedGroupInfo.GroupId=='$sg'].SecurityGroupRuleId" --output text 2>/dev/null); do
              aws ec2 revoke-security-group-ingress --region "$REGION" --group-id "$holder" --security-group-rule-ids "$rid" >/dev/null 2>&1
            done
          done
          aws ec2 delete-security-group --region "$REGION" --group-id "$sg" >/dev/null 2>&1
        done
        [ "$(count_left)" = 0 ] && break
        [ "$(date +%s)" -gt "$end" ] && break
        sleep 10
      done

      # 4) still there: stop destroy so a person can look before the controller is removed
      if [ "$(count_left)" = 0 ]; then echo "forced cleanup done"; exit 0; fi
      echo "ERROR: leftovers remain: $(left_all | tr '\n' ' ')"
      echo "Remove them (or fix the cause), then run terraform destroy again."
      exit 1
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = self.input.windows ? ["PowerShell", "-Command"] : ["bash", "-c"]
    environment = {
      CLUSTER = self.input.cluster
      REGION  = self.input.region
      VPC_ID  = self.input.vpc_id
    }
    command = self.input.windows ? self.input.script_ps : self.input.script_sh
  }

  # 이 리소스가 LB Controller·네임스페이스보다 먼저 삭제되도록 의존 관계를 둠
  # WAF 연결과 인증서는 ALB가 지워져야 삭제됨 → 이 정리 단계가 WAF·인증서 삭제보다 먼저 끝나야 함
  depends_on = [
    helm_release.lbc,
    kubernetes_namespace.keeper,
    aws_wafv2_web_acl.keeper,
    aws_acm_certificate_validation.this,
  ]
}
