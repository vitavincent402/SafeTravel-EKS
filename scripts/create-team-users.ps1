# 팀 IAM 그룹·사용자 생성 (한 번만. terraform destroy와 무관하게 유지됨)
# 이미 2026-11-23에 AWS 콘솔(CloudShell)에서 같은 내용으로 만들었다. 새 계정에서 다시 만들 때만 쓴다.
# 실행: IAM 생성 권한이 있는 관리자 자격으로 .\scripts\create-team-users.ps1
# 비밀번호·액세스 키는 만들지 않는다. 각자 로그인 설정 후 본인 키를 직접 만든다(아래 정책에 허용돼 있음).
$ErrorActionPreference = "Continue"  # PowerShell 5.1에서 2>$null 과 Stop을 같이 쓰면 오류가 나서 Continue 사용
$group = "keeper-team"
# 사람 이름이 아니라 역할 이름 (DB·api 담당, SOC·CI/CD 담당, WEB 담당, RED)
$members = @("keeper-db", "keeper-soc", "keeper-web", "keeper-red")

$policy = @'
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": ["eks:DescribeCluster", "eks:ListClusters"], "Resource": "*" },
    { "Effect": "Allow", "Action": ["ecr:GetAuthorizationToken"], "Resource": "*" },
    { "Effect": "Allow", "Action": ["ecr:DescribeRepositories", "ecr:DescribeImages", "ecr:ListImages", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"], "Resource": "*" },
    { "Effect": "Allow", "Action": ["iam:ChangePassword", "iam:GetUser", "iam:CreateAccessKey", "iam:ListAccessKeys", "iam:UpdateAccessKey", "iam:DeleteAccessKey"], "Resource": "arn:aws:iam::*:user/${aws:username}" }
  ]
}
'@
$policyFile = Join-Path $env:TEMP "keeper-team-policy.json"
[System.IO.File]::WriteAllText($policyFile, $policy, (New-Object System.Text.UTF8Encoding $false))

aws iam create-group --group-name $group 2>$null | Out-Null
aws iam put-group-policy --group-name $group --policy-name keeper-team-basic --policy-document ("file://" + $policyFile)
if ($LASTEXITCODE -ne 0) { Write-Output "그룹 정책 설정 실패. 이 계정에 IAM 권한이 있는지 확인"; exit 1 }

foreach ($m in $members) {
  aws iam get-user --user-name $m 2>$null | Out-Null
  if ($LASTEXITCODE -eq 0) { Write-Output "$m : 이미 있음 (건너뜀)"; continue }
  aws iam create-user --user-name $m --query User.Arn --output text
  aws iam add-user-to-group --group-name $group --user-name $m
}
Write-Output "끝. terraform.tfvars 의 team_members 에 ARN을 넣고 terraform apply."
