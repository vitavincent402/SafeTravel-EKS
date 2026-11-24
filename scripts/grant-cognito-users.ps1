# 팀원에게 Cognito 사용자 풀 하나의 "사용자 관리" 권한을 준다 (테스트 계정 생성·조회 등)
# 풀 설정(앱 클라이언트·도메인·MFA·풀 삭제)은 persistent/의 Terraform이 관리하므로 허용하지 않는다.
# 실행: IAM 권한이 있는 관리자 자격으로 (팀원은 guardrail 정책 때문에 IAM 정책을 만들 수 없다)
#   부여: .\scripts\grant-cognito-users.ps1 -User keeper-db
#   회수: .\scripts\grant-cognito-users.ps1 -User keeper-db -Revoke
# 콘솔은 서울(ap-northeast-2) 리전에서 열어야 한다. 다른 리전은 keeper-team-guardrail의 DenyOutsideSeoul에 걸린다.
param(
  [Parameter(Mandatory = $true)][string]$User,
  [string]$PoolId = "ap-northeast-2_KOszAzPrG",
  [string]$Region = "ap-northeast-2",
  [string]$PolicyName = "keeper-cognito-users",
  [switch]$Revoke
)
$ErrorActionPreference = "Continue"

if ($Revoke) {
  aws iam delete-user-policy --user-name $User --policy-name $PolicyName
  if ($LASTEXITCODE -ne 0) { Write-Output "회수 실패. 정책이 없거나 IAM 권한이 없습니다."; exit 1 }
  Write-Output "회수 완료: $User 에서 $PolicyName 정책을 지웠습니다."
  exit 0
}

$account = (aws sts get-caller-identity --query Account --output text).Trim()
if (-not $account) { Write-Output "계정을 확인하지 못했습니다. `$env:AWS_PROFILE 설정을 확인하세요."; exit 1 }
$pool = "arn:aws:cognito-idp:${Region}:${account}:userpool/${PoolId}"

$policy = @"
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "PoolUsersAndRead",
      "Effect": "Allow",
      "Action": ["cognito-idp:Admin*", "cognito-idp:List*", "cognito-idp:Describe*", "cognito-idp:Get*"],
      "Resource": "$pool" },
    { "Sid": "ConsolePoolList",
      "Effect": "Allow",
      "Action": ["cognito-idp:ListUserPools"],
      "Resource": "*" }
  ]
}
"@
$policyFile = Join-Path $env:TEMP "keeper-cognito-users.json"
[System.IO.File]::WriteAllText($policyFile, $policy, (New-Object System.Text.UTF8Encoding $false))

aws iam put-user-policy --user-name $User --policy-name $PolicyName --policy-document ("file://" + $policyFile)
if ($LASTEXITCODE -ne 0) { Write-Output "정책 설정 실패. 이 계정에 IAM 권한이 있는지, 사용자 이름이 맞는지 확인"; exit 1 }
Write-Output "완료: $User 가 풀 $PoolId 의 사용자를 관리할 수 있습니다 (풀 설정 변경·삭제는 불가)."
Write-Output "콘솔은 서울(ap-northeast-2) 리전에서 여세요. 다 쓰면 -Revoke 로 회수합니다."
