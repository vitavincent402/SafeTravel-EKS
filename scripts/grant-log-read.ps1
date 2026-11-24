# 팀원에게 CloudWatch 로그 그룹 조회 권한을 준다 (한 번만. terraform destroy와 무관하게 유지됨)
# 로그 그룹은 infra/ 가 만들고 매일 destroy로 지워지지만, 이 권한은 로그 그룹 이름 기준이라 계속 유효하다.
# 실행: IAM 권한이 있는 자격(예: keeper-netsec)으로
#   RED: .\scripts\grant-log-read.ps1 -User keeper-red -LogGroup aws-waf-logs-keeper
#   SOC: .\scripts\grant-log-read.ps1 -User keeper-soc -LogGroup /aws/eks/keeper-eks/cluster
# 같은 사용자에게 다시 실행하면 정책이 통째로 바뀐다. 여러 그룹을 주려면 한 번에 쉼표로 적는다.
#   -LogGroup /aws/eks/keeper-eks/cluster,aws-waf-logs-keeper
# 조회·쿼리만 가능하고 로그를 쓰거나 지울 수는 없다.
param(
  [Parameter(Mandatory = $true)][string]$User,
  [Parameter(Mandatory = $true)][string[]]$LogGroup,
  [string]$Region = "ap-northeast-2",
  [string]$PolicyName = "keeper-log-read"
)
$ErrorActionPreference = "Continue"
$account = (aws sts get-caller-identity --query Account --output text).Trim()
if (-not $account) { Write-Output "계정을 확인하지 못했습니다. `$env:AWS_PROFILE 설정을 확인하세요."; exit 1 }

# 로그 그룹마다 ARN 2개(그룹 자체, 그룹 안의 스트림)
$arns = @()
foreach ($g in $LogGroup) {
  $g = $g.Trim()
  $base = "arn:aws:logs:${Region}:${account}:log-group:${g}"
  $arns += ('"' + $base + '"')
  $arns += ('"' + $base + ':*"')
}
$resources = $arns -join ", "

$policy = @"
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow",
      "Action": ["logs:FilterLogEvents", "logs:GetLogEvents", "logs:DescribeLogStreams", "logs:StartQuery"],
      "Resource": [$resources] },
    { "Effect": "Allow",
      "Action": ["logs:DescribeLogGroups", "logs:GetQueryResults", "logs:StopQuery"],
      "Resource": "*" }
  ]
}
"@
$policyFile = Join-Path $env:TEMP "keeper-log-read.json"
[System.IO.File]::WriteAllText($policyFile, $policy, (New-Object System.Text.UTF8Encoding $false))

aws iam put-user-policy --user-name $User --policy-name $PolicyName --policy-document ("file://" + $policyFile)
if ($LASTEXITCODE -ne 0) { Write-Output "정책 설정 실패. 이 계정에 IAM 권한이 있는지, 사용자 이름이 맞는지 확인"; exit 1 }
Write-Output ("완료: {0} 가 다음 로그 그룹을 조회할 수 있습니다: {1}" -f $User, ($LogGroup -join ", "))
Write-Output "(로그 그룹은 infra apply 때 만들어지고 destroy 때 지워집니다. 증적이 필요하면 destroy 전에 쿼리 결과를 저장하세요)"
