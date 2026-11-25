# 무중단 배포 측정(k6) 때 조장이 쓰는 도우미. 단계마다 한 번씩 실행한다 (WEB의 tests/zero-downtime/README.md 참고).
#   .\scripts\measure-zero-downtime.ps1 -Step precheck                 13:50 전 사전 점검
#   .\scripts\measure-zero-downtime.ps1 -Step waf-count                13:55 요청 제한을 Count로 (WAF 규칙 하나만 바뀜)
#   .\scripts\measure-zero-downtime.ps1 -Step restart -Label before-1  restart 1회 (Before 14:03·14:06·14:09, After는 시작 T+3·6·9분)
#   .\scripts\measure-zero-downtime.ps1 -Step waf-restore              14:35 요청 제한을 다시 Block으로
# restart는 keeper-web, keeper-api 를 차례로 다시 시작하고 시각을 화면에 남긴다 (SOC 감사 로그의 patch deployments 시각과 맞춰 보기 위해).
# 복구(waf-restore)를 잊으면 대입 공격 방어가 꺼진 채로 남으니 14:35에 꼭 실행한다.
param(
  [Parameter(Mandatory = $true)][ValidateSet("precheck", "waf-count", "restart", "waf-restore")][string]$Step,
  [string]$Label = "restart",
  [string[]]$Deployments = @("keeper-web", "keeper-api"),
  [string]$Domain = "travelsafe.click"
)
$ErrorActionPreference = "Continue"
$env:AWS_PROFILE = "keeper"
$root = Split-Path -Parent $PSScriptRoot

function Get-RateLimitAction {
  $id = (aws wafv2 list-web-acls --scope REGIONAL --query "WebACLs[?Name=='keeper-waf'].Id | [0]" --output text).Trim()
  $rules = aws wafv2 get-web-acl --name keeper-waf --scope REGIONAL --id $id --query "WebACL.Rules[?Name=='rate-limit'].Action" --output json | ConvertFrom-Json
  if (-not $rules) { return "(규칙 없음)" }
  return (($rules[0].PSObject.Properties | Where-Object { $_.Value -ne $null }) | ForEach-Object { $_.Name }) -join ","
}

function Stamp { return (Get-Date -Format "HH:mm:ss") }

switch ($Step) {
  "precheck" {
    Write-Host ("[" + (Stamp) + "] 사전 점검") -ForegroundColor Cyan
    Write-Host "--- 파드 (모두 Running·Ready) ---"
    kubectl -n keeper get pods
    Write-Host "--- ALB에 WAF가 붙어 있는지 ---"
    $ann = kubectl -n keeper get ingress keeper -o jsonpath="{.metadata.annotations}"
    if ($ann -match "wafv2-acl-arn") { Write-Host "wafv2-acl-arn 있음 (값은 기록하지 않음)" -ForegroundColor Green } else { Write-Host "wafv2-acl-arn 없음" -ForegroundColor Red }
    Write-Host "--- 사이트 응답 ---"
    curl.exe -sI ("https://" + $Domain) | Select-String "HTTP/"
    Write-Host "--- 이 시각의 ALB IP 기록 (FAIL·INVALID 줄의 ip= 와 비교) ---"
    nslookup $Domain 8.8.8.8 2>&1 | Select-String "Address" | Select-Object -Skip 1
    Write-Host "--- 도메인이 EKS(nginx)로 가는지 (Server: nginx 여야 함) ---"
    curl.exe -4 -s -D - -o NUL ("https://" + $Domain + "/") | Select-String "Server|Via"
    Write-Host "--- 요청 제한 규칙의 현재 동작 ---"
    Write-Host (Get-RateLimitAction)
  }
  "waf-count" {
    Write-Host ("[" + (Stamp) + "] 요청 제한을 Count로 바꿉니다 (WAF 규칙만)") -ForegroundColor Cyan
    Push-Location (Join-Path $root "infra")
    terraform apply -input=false -auto-approve "-var=rate_limit_action=count" "-target=aws_wafv2_web_acl.keeper"
    Pop-Location
    $a = Get-RateLimitAction
    $color = "Red"; if ($a -eq "Count") { $color = "Green" }
    Write-Host ("[" + (Stamp) + "] rate-limit 동작: " + $a + "   (Count 여야 측정을 시작할 수 있음)") -ForegroundColor $color
  }
  "restart" {
    Write-Host ("[" + (Stamp) + "] " + $Label + " restart 시작") -ForegroundColor Cyan
    foreach ($d in $Deployments) {
      kubectl -n keeper rollout restart ("deploy/" + $d)
      Write-Host ("[" + (Stamp) + "] " + $Label + " " + $d + " restart 요청함")
    }
    Write-Host ("[" + (Stamp) + "] " + $Label + " 끝. 위 시각을 기록해 두세요 (SOC 감사 로그의 patch deployments 와 대조)") -ForegroundColor Green
  }
  "waf-restore" {
    Write-Host ("[" + (Stamp) + "] 요청 제한을 Block으로 되돌립니다") -ForegroundColor Cyan
    Push-Location (Join-Path $root "infra")
    terraform apply -input=false -auto-approve "-target=aws_wafv2_web_acl.keeper"
    Pop-Location
    $a = Get-RateLimitAction
    $color = "Red"; if ($a -eq "Block") { $color = "Green" }
    Write-Host ("[" + (Stamp) + "] rate-limit 동작: " + $a + "   (Block 이어야 복구 완료)") -ForegroundColor $color
  }
}
