# 배포용 GitHub Environment(필수 검토자 + main 브랜치만)를 만든다. 한 번만 실행.
# 왜: main에 합쳐진 워크플로는 AWS 배포 역할(keeper Edit, pods/exec 가능)을 받을 수 있다.
#     Environment를 거치게 하면 검토자가 승인한 배포만 그 역할을 받는다 (docs: 접근 = main 병합 권한의 개선안).
#
# 순서 (순서가 틀리면 배포가 실패한다):
#   1) 이 스크립트로 Environment 만들기 (검토자 지정)
#   2) infra/terraform.tfvars 에 github_deploy_environment = "production" 넣고 terraform apply (신뢰 정책에 environment 주체 추가, main 직접 실행도 아직 허용)
#   3) .github/workflows/deploy.yml 의 deploy 작업에 environment: production 한 줄을 넣은 PR 병합 (이 뒤로 배포는 검토자 승인 대기)
#   4) 배포가 한 번 승인되어 성공하는 것을 확인한 뒤 github_oidc_allow_main_ref = false 로 apply (main 직접 실행 차단)
# 주의: terraform apply 마지막 단계(bootstrap_deploy)도 같은 워크플로를 돌리므로 3) 이후에는 구축 때마다 검토자 승인이 필요하다.
#
# 실행: gh auth login 이 된 PowerShell에서, 저장소 관리자 권한으로
#   .\scripts\setup-deploy-environment.ps1 -Reviewers vitavincent402,KIMMANSOO-SLEK -Repo vitavincent402/SafeTravel-EKS
#   -PreventSelfReview 를 붙이면 배포를 시작한 사람은 자기 배포를 승인할 수 없다(검토자가 2명 이상이어야 함)
param(
  [Parameter(Mandatory = $true)][string[]]$Reviewers,
  [string]$Repo = "vitavincent402/SafeTravel-EKS",
  [string]$Environment = "production",
  [switch]$PreventSelfReview
)
$ErrorActionPreference = "Stop"

$ids = @()
foreach ($r in $Reviewers) {
  $id = gh api "users/$($r.Trim())" --jq ".id"
  if (-not $id) { Write-Output "사용자를 찾지 못했습니다: $r"; exit 1 }
  $ids += [int]$id
}
$reviewerObjs = @($ids | ForEach-Object { @{ type = "User"; id = $_ } })
$body = @{
  wait_timer              = 0
  prevent_self_review     = [bool]$PreventSelfReview
  reviewers               = $reviewerObjs
  deployment_branch_policy = @{ protected_branches = $false; custom_branch_policies = $true }
} | ConvertTo-Json -Depth 6

$tmp = Join-Path $env:TEMP "keeper-env.json"
[System.IO.File]::WriteAllText($tmp, $body, (New-Object System.Text.UTF8Encoding $false))
gh api -X PUT "repos/$Repo/environments/$Environment" --input $tmp | Out-Null

# main 브랜치에서 시작한 배포만 이 Environment를 쓸 수 있게 한다
gh api -X POST "repos/$Repo/environments/$Environment/deployment-branch-policies" -f name=main -f type=branch 2>$null | Out-Null

# 위 명령은 "이미 있음" 오류를 숨기려고 2>$null 을 쓴다. 실제 실패(네트워크·권한)도 숨겨지므로 결과를 확인한다.
# main 정책이 없으면 허용 명단이 비어 어떤 브랜치도 배포할 수 없게 된다.
$names = gh api "repos/$Repo/environments/$Environment/deployment-branch-policies" --jq ".branch_policies[].name"
if ($names -notcontains "main") {
  Write-Output "main 브랜치 정책이 없습니다. 이대로면 배포가 막힙니다. 다시 실행하거나 GitHub 설정에서 추가하세요."
  exit 1
}

Write-Output ("완료: Environment '{0}' 검토자 {1}명, main 브랜치만 허용, 본인 승인 금지={2}" -f $Environment, $Reviewers.Count, [bool]$PreventSelfReview)
Write-Output "다음: infra/terraform.tfvars 에 github_deploy_environment = `"$Environment`" 를 넣고 terraform apply (스크립트 머리말의 순서 참고)"
