# 팀원 IAM 사용자 생성 (한 번만 실행. terraform destroy와 무관하게 유지됨)
# 실행: IAM 사용자를 만들 수 있는 관리자 자격으로 (예: $env:AWS_PROFILE = "<관리자 프로필>")
#   .\scripts\create-team-users.ps1
# 비밀번호는 화면에 한 번만 출력된다. 각자에게 전달하고, 첫 로그인 때 바꾸도록 설정됨.
$ErrorActionPreference = "Continue"  # PowerShell 5.1에서 2>$null 과 Stop을 같이 쓰면 오류가 나서 Continue 사용
$group = "keeper-team"
$members = @("keeper-yujin", "keeper-junil", "keeper-mansu", "keeper-seongrim")

$policy = @'
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": ["eks:DescribeCluster", "eks:ListClusters"], "Resource": "*" },
    { "Effect": "Allow", "Action": ["ecr:GetAuthorizationToken"], "Resource": "*" },
    { "Effect": "Allow", "Action": ["ecr:DescribeRepositories", "ecr:DescribeImages", "ecr:ListImages", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"], "Resource": "*" },
    { "Effect": "Allow", "Action": ["iam:ChangePassword", "iam:GetUser"], "Resource": "arn:aws:iam::*:user/${aws:username}" }
  ]
}
'@
$policyFile = Join-Path $env:TEMP "keeper-team-policy.json"
[System.IO.File]::WriteAllText($policyFile, $policy, (New-Object System.Text.UTF8Encoding $false))

aws iam create-group --group-name $group 2>$null | Out-Null
aws iam put-group-policy --group-name $group --policy-name keeper-team-basic --policy-document ("file://" + $policyFile)
if ($LASTEXITCODE -ne 0) { Write-Output "그룹 정책 설정 실패. 이 계정에 IAM 권한이 있는지 확인"; exit 1 }
$account = aws sts get-caller-identity --query Account --output text

foreach ($m in $members) {
  aws iam get-user --user-name $m 2>$null | Out-Null
  if ($LASTEXITCODE -eq 0) { Write-Output "$m : 이미 있음 (건너뜀)"; continue }
  aws iam create-user --user-name $m | Out-Null
  aws iam add-user-to-group --group-name $group --user-name $m
  $pw = "Kp!" + [guid]::NewGuid().ToString("N").Substring(0, 14)
  aws iam create-login-profile --user-name $m --password $pw --password-reset-required | Out-Null
  Write-Output "$m : 콘솔 로그인 https://$account.signin.aws.amazon.com/console  임시 비밀번호 $pw"
}
Write-Output "끝. 이제 terraform.tfvars 의 team_members 에 ARN을 넣고 terraform apply."
