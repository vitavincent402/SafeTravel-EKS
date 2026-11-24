# Before / After 점검 결과를 나란히 비교
#   powershell -ExecutionPolicy Bypass -File scripts\compare-checks.ps1 -Before evidence\security-check-before-<시각>.csv -After evidence\security-check-after-<시각>.csv
# 결과: 화면 표 + evidence\before-after-<시각>.md (발표 자료에 붙여 쓰는 표)

param(
  [Parameter(Mandatory = $true)][string]$Before,
  [Parameter(Mandatory = $true)][string]$After
)

$b = @(Import-Csv -Path $Before -Encoding UTF8)
$a = @(Import-Csv -Path $After -Encoding UTF8)
if ($b.Count -eq 0 -or $a.Count -eq 0) { Write-Host "비교할 결과 파일이 비어 있습니다." -ForegroundColor Red; exit 1 }

$rows = @()
foreach ($x in $b) {
  $y = $a | Where-Object { $_.ID -eq $x.ID } | Select-Object -First 1
  $afterResult = if ($y) { $y.Result } else { "-" }
  $change = if ($x.Result -eq $afterResult) { "변화 없음" } elseif ($x.Result -eq "FAIL" -and $afterResult -eq "PASS") { "개선 (FAIL -> PASS)" } else { "$($x.Result) -> $afterResult" }
  $rows += [pscustomobject]@{ ID = $x.ID; Area = $x.Area; Item = $x.Item; Before = $x.Result; After = $afterResult; Change = $change; AfterDetail = $(if ($y) { $y.Detail } else { "" }) }
}

function Count-Of($list, $name) { @($list | Where-Object { $_.Result -eq $name }).Count }
$summary = ("Before: PASS {0} / WARN {1} / FAIL {2}  ->  After: PASS {3} / WARN {4} / FAIL {5}" -f (Count-Of $b "PASS"), (Count-Of $b "WARN"), (Count-Of $b "FAIL"), (Count-Of $a "PASS"), (Count-Of $a "WARN"), (Count-Of $a "FAIL"))

Write-Host ""
$rows | Format-Table ID, Area, Item, Before, After, Change -AutoSize
Write-Host $summary -ForegroundColor Cyan

$EvidenceDir = Split-Path -Parent (Resolve-Path $After)
$md = Join-Path $EvidenceDir ("before-after-{0}.md" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
$lines = @(
  "# 보안 통제 적용 전/후 점검 비교",
  "",
  "- Before 결과: $(Split-Path -Leaf $Before)",
  "- After 결과: $(Split-Path -Leaf $After)",
  "- $summary",
  "",
  "| ID | 영역 | 항목 | Before | After | 변화 |",
  "|---|---|---|---|---|---|"
)
foreach ($r in $rows) { $lines += ("| {0} | {1} | {2} | {3} | {4} | {5} |" -f $r.ID, $r.Area, $r.Item, $r.Before, $r.After, $r.Change) }
[IO.File]::WriteAllLines($md, $lines, (New-Object System.Text.UTF8Encoding($true)))
Write-Host "저장: $md"
