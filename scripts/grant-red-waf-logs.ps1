# keeper-red 에게 WAF 로그 조회 권한을 준다 (한 번만. terraform destroy와 무관하게 유지됨)
# WAF 로그 그룹(aws-waf-logs-keeper)은 infra/ 가 만들고 매일 destroy로 지워지지만, 이 권한은 이름 기준이라 계속 유효하다.
# 실행: IAM 권한이 있는 자격(예: keeper-netsec)으로 .\scripts\grant-red-waf-logs.ps1
# 조회만 가능하고 로그를 쓰거나 지울 수는 없다.
param(
  [string]$User   = "keeper-red",
  [string]$Region = "ap-northeast-2",
  [string]$LogGroup = "aws-waf-logs-keeper"
)
$ErrorActionPreference = "Continue"
$account = (aws sts get-caller-identity --query Account --output text).Trim()
if (-not $account) { Write-Output "계정을 확인하지 못했습니다. `$env:AWS_PROFILE 설정을 확인하세요."; exit 1 }
$lg = "arn:aws:logs:${Region}:${account}:log-group:${LogGroup}"

$policy = @"
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow",
      "Action": ["logs:FilterLogEvents", "logs:GetLogEvents", "logs:DescribeLogStreams", "logs:StartQuery"],
      "Resource": ["$lg", "${lg}:*"] },
    { "Effect": "Allow",
      "Action": ["logs:DescribeLogGroups", "logs:GetQueryResults", "logs:StopQuery"],
      "Resource": "*" }
  ]
}
"@
$policyFile = Join-Path $env:TEMP "keeper-red-waf-logs.json"
[System.IO.File]::WriteAllText($policyFile, $policy, (New-Object System.Text.UTF8Encoding $false))

aws iam put-user-policy --user-name $User --policy-name keeper-red-waf-logs-read --policy-document ("file://" + $policyFile)
if ($LASTEXITCODE -ne 0) { Write-Output "정책 설정 실패. 이 계정에 IAM 권한이 있는지, 사용자 이름이 맞는지 확인"; exit 1 }
Write-Output "완료: $User 가 $LogGroup 로그를 조회할 수 있습니다 (로그 그룹은 infra apply 때 만들어짐)."
Write-Output "RED 사용법: aws logs filter-log-events --log-group-name $LogGroup --region $Region --filter-pattern BLOCK --max-items 20"
