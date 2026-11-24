# keeper 보안 자체 점검
# 멘토 키트 hannctl_mentoring s4-eks-audit-hardening/checks/cluster_checks.py(DEMO-01~12)를
# 우리 환경(keeper-eks, keeper 네임스페이스)에 맞게 옮기고 항목을 추가했습니다.
#
# 실행 (apply가 끝나 클러스터가 떠 있을 때, keeper 폴더에서):
#   $env:AWS_PROFILE = "keeper"
#   powershell -ExecutionPolicy Bypass -File scripts\security-check.ps1
# 결과: 화면 표 + evidence\security-check-<시각>.md / .csv  (evidence 폴더는 git에 올라가지 않음)
# Before/After 시연: -Label before / -Label after 를 붙이면 파일 이름에 구분이 들어갑니다 (README "Before / After 시연")
#
# PASS = 기준 충족, FAIL = 고쳐야 함, WARN = 알고 둔 예외(사유를 상세에 적음)

param(
  [string]$Cluster   = "keeper-eks",
  [string]$Region    = "ap-northeast-2",
  [string]$Namespace = "keeper",
  [string]$Label     = ""      # 결과 파일 이름에 붙일 구분 (예: before, after)
)

$ErrorActionPreference = "Continue"
$RepoRoot  = Split-Path -Parent $PSScriptRoot
$AttackDir = Join-Path $RepoRoot "tests\attack"
$OnWindows = ($env:OS -eq "Windows_NT")
$CurlExe   = if ($OnWindows) { "curl.exe" } else { "curl" }
$NullFile  = if ($OnWindows) { "NUL" } else { "/dev/null" }

$Results = New-Object System.Collections.Generic.List[object]
$Timer   = [Diagnostics.Stopwatch]::StartNew()

function Add-Result([string]$Id, [string]$Area, [string]$Item, [string]$Status, [string]$Detail) {
  $Results.Add([pscustomobject]@{ ID = $Id; Area = $Area; Item = $Item; Result = $Status; Detail = $Detail })
  $color = switch ($Status) { "PASS" { "Green" } "WARN" { "Yellow" } default { "Red" } }
  Write-Host ("  [{0}] {1} {2} - {3}" -f $Status, $Id, $Item, $Detail) -ForegroundColor $color
}

# kubectl / aws 결과(JSON)를 객체로. 실패하면 $null
function Get-KubeJson([string[]]$KArgs) {
  $out = & kubectl @KArgs -o json 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $out) { return $null }
  # kubectl -o json의 최상위는 항상 객체 하나(목록은 .items 안)이므로 그대로 반환
  return (($out -join "`n") | ConvertFrom-Json)
}
function Get-AwsText([string[]]$AArgs) {
  $out = & aws @AArgs --region $Region --output text 2>$null
  if ($LASTEXITCODE -ne 0) { return "" }
  return (($out -join " ") -replace "\s+", " ").Trim()
}
function Test-DryRunDenied([string]$File) {
  $msg = (& kubectl apply -n $Namespace --dry-run=server -f $File 2>&1 | Out-String).Trim()
  return @{ Denied = ($LASTEXITCODE -ne 0); Message = $msg }
}
function Get-HttpCode([string]$Url, [switch]$Insecure) {
  $curlArgs = @("-s", "-o", $NullFile, "-w", "%{http_code}", "--max-time", "10")
  if ($Insecure) { $curlArgs += "-k" }   # ALB 주소는 인증서의 도메인과 달라서 인증서 이름 검사만 건너뜀 (점검용)
  $code = & $CurlExe @curlArgs $Url 2>$null
  if (-not $code) { return "ERR" }
  return "$code"
}

Write-Host ""
Write-Host "keeper 보안 자체 점검  (클러스터 $Cluster / 네임스페이스 $Namespace)" -ForegroundColor Cyan
& aws eks update-kubeconfig --name $Cluster --region $Region 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
  Write-Host "클러스터에 접속할 수 없습니다. apply가 끝났는지, `$env:AWS_PROFILE 설정을 확인하세요." -ForegroundColor Red
  exit 1
}

# ---------------------------------------------------------------- 쿠버네티스 안쪽
Write-Host "`n[쿠버네티스]" -ForegroundColor Cyan

# S01 PSA
$ns = Get-KubeJson @("get", "ns", $Namespace)
$psa = if ($ns) { $ns.metadata.labels.'pod-security.kubernetes.io/enforce' } else { $null }
if (-not $psa) { $psa = "없음" }
Add-Result "S01" "파드 보안" "업무 네임스페이스 PSA restricted 강제" $(if ($psa -eq "restricted") { "PASS" } else { "FAIL" }) "enforce=$psa"

# S02 cluster-admin 과다 권한
$found = @()
$crbs = Get-KubeJson @("get", "clusterrolebindings")
if ($crbs) {
  foreach ($b in $crbs.items) {
    if ($b.roleRef.name -ne "cluster-admin") { continue }
    foreach ($s in @($b.subjects)) {
      if (-not $s) { continue }
      $n = [string]$s.name
      if ($n.StartsWith("system:") -or $n.StartsWith("eks:")) { continue }
      $found += ("{0}->{1}/{2}" -f $b.metadata.name, $s.kind, $n)
    }
  }
}
Add-Result "S02" "RBAC" "cluster-admin이 시스템 외 주체에 묶여 있지 않음" $(if ($found.Count -eq 0) { "PASS" } else { "FAIL" }) $(if ($found.Count -eq 0) { "시스템 외 주체 없음 (사람 권한은 EKS access entry로 관리)" } else { $found -join ", " })

# S03 default-deny NetworkPolicy
$denyName = $null
$nps = Get-KubeJson @("get", "networkpolicy", "-n", $Namespace)
if ($nps) {
  foreach ($p in $nps.items) {
    $sp = $p.spec
    $selEmpty = (-not $sp.podSelector) -or (@($sp.podSelector.PSObject.Properties).Count -eq 0)
    $types = @($sp.policyTypes)
    if ($selEmpty -and ($types -contains "Ingress") -and ($types -contains "Egress") -and (-not $sp.ingress) -and (-not $sp.egress)) {
      $denyName = $p.metadata.name; break
    }
  }
}
Add-Result "S03" "네트워크" "default-deny NetworkPolicy (전부 막고 필요한 것만 허용)" $(if ($denyName) { "PASS" } else { "FAIL" }) $(if ($denyName) { $denyName } else { "기본 거부 정책 없음" })

# S04 입장 정책 4종
$want = @("keeper-disallow-privileged", "keeper-disallow-host-path", "keeper-require-run-as-non-root", "keeper-trusted-registry-only")
$have = @()
$vapb = Get-KubeJson @("get", "validatingadmissionpolicybindings")
if ($vapb) {
  foreach ($b in $vapb.items) {
    if (($want -contains $b.metadata.name) -and (@($b.spec.validationActions) -contains "Deny")) { $have += $b.metadata.name }
  }
}
Add-Result "S04" "정책 통제" "입장 정책 4종 Deny 적용 (privileged/hostPath/root/신뢰 레지스트리)" $(if ($have.Count -eq $want.Count) { "PASS" } else { "FAIL" }) ("{0}/{1}개 적용" -f $have.Count, $want.Count)

# S05 default SA 토큰
$sa = Get-KubeJson @("get", "sa", "default", "-n", $Namespace)
$auto = if ($sa -and ($null -ne $sa.automountServiceAccountToken)) { [string]$sa.automountServiceAccountToken } else { "설정 없음(기본 true)" }
Add-Result "S05" "서비스 계정" "default SA 토큰 자동 마운트 끔" $(if ($auto -eq "False") { "PASS" } else { "FAIL" }) "automountServiceAccountToken=$auto"

# S06 앱 SA가 Secret을 못 읽음
$canRead = @()
foreach ($app in @("web", "api", "vault")) {
  $ans = (& kubectl auth can-i get secrets -n $Namespace --as "system:serviceaccount:${Namespace}:keeper-$app" 2>$null | Out-String).Trim()
  if ($ans -ne "no") { $canRead += "keeper-$app=$ans" }
}
Add-Result "S06" "RBAC" "앱 서비스 계정이 쿠버네티스 Secret을 읽을 수 없음" $(if ($canRead.Count -eq 0) { "PASS" } else { "FAIL" }) $(if ($canRead.Count -eq 0) { "web·api·vault 모두 no" } else { $canRead -join ", " })

# S07~S10 위험 파드 거부 (서버 dry-run, 실제로 만들지 않음)
$attacks = @(
  @("S07", "privileged-pod.yaml",          "특권(privileged) 파드 생성 거부"),
  @("S08", "hostpath-pod.yaml",            "hostPath(노드 파일시스템) 파드 생성 거부"),
  @("S09", "root-pod.yaml",                "root 실행 파드 생성 거부"),
  @("S10", "untrusted-registry-pod.yaml",  "외부 레지스트리 이미지 파드 생성 거부")
)
foreach ($a in $attacks) {
  $f = Join-Path $AttackDir $a[1]
  if (-not (Test-Path $f)) { Add-Result $a[0] "파드 보안" $a[2] "FAIL" "$($a[1]) 파일 없음"; continue }
  $r = Test-DryRunDenied $f
  $by = if ($r.Message -match "ValidatingAdmissionPolicy '([^']+)'") { $Matches[1] } elseif ($r.Message -match "PodSecurity") { "PodSecurity" } else { "" }
  Add-Result $a[0] "파드 보안" $a[2] $(if ($r.Denied) { "PASS" } else { "FAIL" }) $(if ($r.Denied) { "거부됨 $by".Trim() } else { "생성이 허용됨" })
}

# S11 kube-bench 정기 점검
$cj = Get-KubeJson @("get", "cronjob", "-n", "security-audit")
$cjNames = if ($cj) { @($cj.items | ForEach-Object { $_.metadata.name }) } else { @() }
Add-Result "S11" "점검 자동화" "kube-bench(CIS) 정기 점검 CronJob 등록" $(if ($cjNames.Count -gt 0) { "PASS" } else { "FAIL" }) $(if ($cjNames.Count -gt 0) { $cjNames -join ", " } else { "정기 점검 없음" })

# ---------------------------------------------------------------- 서비스 입구
Write-Host "`n[서비스 입구]" -ForegroundColor Cyan
$albHost = (& kubectl get ingress keeper -n $Namespace -o "jsonpath={.status.loadBalancer.ingress[0].hostname}" 2>$null | Out-String).Trim()
if (-not $albHost) {
  Add-Result "S12" "가용성" "서비스 정상 응답 (ALB → web /healthz 200)" "FAIL" "Ingress에 ALB 주소가 아직 없음"
  Add-Result "S13" "WAF" "XSS 공격 요청 차단 (403)" "FAIL" "ALB 주소 없음"
} else {
  $ok = Get-HttpCode "http://$albHost/healthz"
  $note = "HTTP $ok"
  if ($ok -eq "301" -or $ok -eq "308") {
    # 도메인·인증서를 쓰면 ALB가 80 → 443으로 넘기므로, 넘어간 HTTPS 쪽 응답을 확인
    $ok = Get-HttpCode "https://$albHost/healthz" -Insecure
    $note = "HTTP 80은 HTTPS로 이동(301), HTTPS $ok"
  }
  Add-Result "S12" "가용성" "서비스 정상 응답 (ALB → web /healthz 200)" $(if ($ok -eq "200") { "PASS" } else { "FAIL" }) $note
  $xss = Get-HttpCode "http://$albHost/?q=%3Cscript%3Ealert(1)%3C%2Fscript%3E"
  Add-Result "S13" "WAF" "XSS 공격 요청 차단 (403)" $(if ($xss -eq "403") { "PASS" } else { "FAIL" }) "HTTP $xss"
}

# ---------------------------------------------------------------- AWS 설정
Write-Host "`n[AWS 설정]" -ForegroundColor Cyan

# S14 감사 로그
$logTypes = Get-AwsText @("eks", "describe-cluster", "--name", $Cluster, "--query", "cluster.logging.clusterLogging[?enabled].types[]")
Add-Result "S14" "감사 로그" "EKS API 감사 로그(audit) CloudWatch 수집" $(if ($logTypes -match "audit") { "PASS" } else { "FAIL" }) $(if ($logTypes) { "enabled=$logTypes" } else { "꺼짐" })

# S15 API 엔드포인트 공개 범위 (알고 둔 예외)
$cidrs = Get-AwsText @("eks", "describe-cluster", "--name", $Cluster, "--query", "cluster.resourcesVpcConfig.publicAccessCidrs")
if ($cidrs -match "0\.0\.0\.0/0") {
  Add-Result "S15" "AWS 설정" "EKS API 엔드포인트 공개 범위 제한" "WARN" "0.0.0.0/0 공개 - GitHub Actions(IP 고정 불가)가 helm 배포를 하기 때문. 접속은 IAM 인증 + access entry로 제한"
} else {
  Add-Result "S15" "AWS 설정" "EKS API 엔드포인트 공개 범위 제한" "PASS" "허용 CIDR: $cidrs"
}

# S16 노드 IMDSv2 + hop limit 1
$imds = Get-AwsText @("ec2", "describe-instances", "--filters", "Name=tag:eks:cluster-name,Values=$Cluster", "Name=instance-state-name,Values=running", "--query", "Reservations[].Instances[].MetadataOptions.[HttpTokens,HttpPutResponseHopLimit]")
$pairs = @()
$tok = @($imds -split " " | Where-Object { $_ })
for ($i = 0; $i + 1 -lt $tok.Count; $i += 2) { $pairs += ,@($tok[$i], $tok[$i + 1]) }
$imdsOk = ($pairs.Count -gt 0) -and (@($pairs | Where-Object { $_[0] -ne "required" -or $_[1] -ne "1" }).Count -eq 0)
Add-Result "S16" "AWS 설정" "노드 IMDSv2 필수 + hop limit 1 (파드의 노드 자격 증명 탈취 차단)" $(if ($imdsOk) { "PASS" } else { "FAIL" }) ("노드 {0}대: {1}" -f $pairs.Count, $imds)

# S17 RDS
$rds = Get-AwsText @("rds", "describe-db-instances", "--db-instance-identifier", "keeper-db", "--query", "DBInstances[0].[StorageEncrypted,PubliclyAccessible]")
Add-Result "S17" "데이터" "RDS 저장소 암호화 + 외부 비공개" $(if ($rds -match "^True False$") { "PASS" } else { "FAIL" }) "암호화/공개 = $rds"

# S18 서류 버킷 공개 차단
$bucket = Get-AwsText @("s3api", "list-buckets", "--query", 'Buckets[?starts_with(Name,`keeper-docs-`)].Name | [0]')
if (-not $bucket -or $bucket -eq "None") {
  Add-Result "S18" "데이터" "서류 S3 버킷 퍼블릭 접근 4종 차단" "FAIL" "버킷을 찾지 못함"
} else {
  $pab = Get-AwsText @("s3api", "get-public-access-block", "--bucket", $bucket, "--query", "PublicAccessBlockConfiguration.[BlockPublicAcls,IgnorePublicAcls,BlockPublicPolicy,RestrictPublicBuckets]")
  Add-Result "S18" "데이터" "서류 S3 버킷 퍼블릭 접근 4종 차단" $(if ($pab -eq "True True True True") { "PASS" } else { "FAIL" }) "$bucket : $pab"
}

# S19 ECR
$ecr = Get-AwsText @("ecr", "describe-repositories", "--repository-names", "keeper/web", "keeper/api", "keeper/vault", "--query", "repositories[].[imageTagMutability,imageScanningConfiguration.scanOnPush]")
$ecrTok = @($ecr -split " " | Where-Object { $_ })
$ecrOk = ($ecrTok.Count -eq 6) -and (@($ecrTok | Where-Object { $_ -eq "IMMUTABLE" }).Count -eq 3) -and (@($ecrTok | Where-Object { $_ -eq "True" }).Count -eq 3)
Add-Result "S19" "공급망" "ECR 태그 덮어쓰기 금지 + 푸시 시 스캔" $(if ($ecrOk) { "PASS" } else { "FAIL" }) $ecr

# S20 팀원 권한 등급: 본인(인프라 담당) 외에는 클러스터 전체 관리자 권한이 없어야 함 (최소 권한)
$callerArn = Get-AwsText @("sts", "get-caller-identity", "--query", "Arn")
$entries = @((Get-AwsText @("eks", "list-access-entries", "--cluster-name", $Cluster, "--query", "accessEntries[]")) -split " " | Where-Object { $_ })
$admins = @()
foreach ($e in $entries) {
  if ($e -eq $callerArn) { continue }
  $pol = Get-AwsText @("eks", "list-associated-access-policies", "--cluster-name", $Cluster, "--principal-arn", $e, "--query", "associatedAccessPolicies[].policyArn")
  if ($pol -match "AmazonEKSClusterAdminPolicy") { $admins += ($e -replace "^.*/", "") }
}
if ($entries.Count -eq 0) {
  Add-Result "S20" "RBAC" "팀원 권한 등급 (클러스터 전체 관리자는 인프라 담당만)" "FAIL" "access entry 조회 실패"
} else {
  $s20Ok = ($admins.Count -eq 0)
  $s20Detail = if ($s20Ok) { "access entry {0}개 중 클러스터 전체 관리자 없음 (본인 제외)" -f $entries.Count } else { "클러스터 전체 관리자: " + ($admins -join ", ") }
  Add-Result "S20" "RBAC" "팀원 권한 등급 (클러스터 전체 관리자는 인프라 담당만)" $(if ($s20Ok) { "PASS" } else { "FAIL" }) $s20Detail
}

# ---------------------------------------------------------------- 요약과 저장
$Timer.Stop()
$pass = @($Results | Where-Object { $_.Result -eq "PASS" }).Count
$warn = @($Results | Where-Object { $_.Result -eq "WARN" }).Count
$fail = @($Results | Where-Object { $_.Result -eq "FAIL" }).Count
$total = $Results.Count
$secs = [math]::Round($Timer.Elapsed.TotalSeconds)

Write-Host ""
Write-Host ("결과: PASS {0} / WARN {1} / FAIL {2}  (전체 {3}개, {4}초)" -f $pass, $warn, $fail, $total, $secs) -ForegroundColor $(if ($fail -eq 0) { "Green" } else { "Yellow" })

$EvidenceDir = Join-Path $RepoRoot "evidence"
New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$tag = if ($Label) { "$Label-" } else { "" }
$csv = Join-Path $EvidenceDir "security-check-$tag$stamp.csv"
$md  = Join-Path $EvidenceDir "security-check-$tag$stamp.md"
$Results | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8

$lines = @(
  "# keeper 보안 자체 점검 결과",
  "",
  ("- 시각: {0}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss")),
  ("- 클러스터: {0} / 네임스페이스: {1}" -f $Cluster, $Namespace),
  ("- 구분: {0}" -f $(if ($Label) { $Label } else { "(없음)" })),
  ("- 결과: PASS {0} / WARN {1} / FAIL {2} (전체 {3}개, 소요 {4}초)" -f $pass, $warn, $fail, $total, $secs),
  "",
  "| ID | 영역 | 항목 | 결과 | 상세 |",
  "|---|---|---|---|---|"
)
foreach ($r in $Results) { $lines += ("| {0} | {1} | {2} | {3} | {4} |" -f $r.ID, $r.Area, $r.Item, $r.Result, ($r.Detail -replace "\|", "/")) }
[IO.File]::WriteAllLines($md, $lines, (New-Object System.Text.UTF8Encoding($true)))

Write-Host "저장: $md"
Write-Host "      $csv"
if ($fail -gt 0) { exit 2 } else { exit 0 }
