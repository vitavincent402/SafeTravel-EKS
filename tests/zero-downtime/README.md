# 무중단 배포 검증 (k6) — WEB 담당

배포로 파드가 교체되는 동안 사이트에 일정한 속도로 요청을 보내고, 실패가 몇 건 나는지 숫자로 잽니다.
차트의 무중단 설정(`rollout`, values.yaml)을 넣기 전(Before)과 후(After)를 같은 조건으로 비교합니다.

## 왜
- 파드 2개 + 롤링 업데이트라 이론상 무중단이지만, ALB가 파드 IP로 직접 보내는 구조(target-type ip)에서
  preStop 대기가 없으면 꺼지는 파드로 요청이 가서 502가 잠깐 날 수 있습니다.
- 시나리오 4번(진단 → 하드닝 → 재진단 → 증적 → 재발 방지)을 가용성 쪽에서 숫자로 보여 줍니다.

## 지키는 것 (SOC·조장과 합의)
- 보내는 주소: `/`, `/healthz`, `/api/healthz` 만. **로그인 경로는 보내지 않습니다.**
- User-Agent: `keeper-zero-downtime-test` (로그에서 이 시험만 골라낼 수 있게)
- 요청 속도: 기본 초당 5건(5분 1,500건). **WAF 요청 제한은 IP당 5분 1,000건**(infra/variables.tf `rate_limit` 기본값, waf.tf에서 `limit = var.rate_limit`로 씀. 11/25 10:35:25에 300 → 1,000으로 적용, 13:23 CLI로 라이브 값 1,000·5분·Block 확인)이라, 측정 시간에는 조장이 rate-limit 규칙을 Count로 바꿔 둡니다(전환 13:55, 복구 14:35). 전환·복구 시각은 CloudTrail UpdateWebACL로, 복구 뒤 한도·동작은 `aws wafv2 get-web-acl`로 조장이 확인해 공유합니다.
  그 밖의 시간에 돌릴 때는 `RATE=1`, 짧게(1분 이하)만 돌립니다.
- 실패는 두 묶음으로 따로 셉니다. **배포 영향**(502·503·504·500·연결 실패/시간 초과)이 무중단 판단 기준이고, **WAF 영향**(403·429)은 따로 봅니다.
- 응답의 Server·Via를 보고 EKS가 아닌 곳이 답한 것은 **무효**로 따로 셉니다(성공·실패 어디에도 넣지 않음). **무효가 1건이라도 있는 구간은 재측정**합니다(SOC 요청). DNS 캐시로 옛 2.5차 CloudFront에 가는 경우를 걸러 내려는 것입니다. 우리 쪽 Server는 web `nginx`, api `keeper`, ALB·WAF가 직접 만든 응답 `awselb/2.0`이라 이 셋은 정상 판정에 그대로 씁니다(ALB의 502·503·504가 배포 영향의 핵심이므로 빠지면 안 됨).
- 403·429가 합쳐 5건이 되면 WAF에 걸린 것으로 보고 시험을 스스로 멈춥니다. 멈추면 바로 SOC에 알립니다.
- User-Agent는 로그에서 골라내는 용도일 뿐이고, 알림이나 WAF에서 빼 주지는 않습니다.
- 요청마다 시각을 CSV 파일로 남겨, 감사 로그의 restart 시각과 맞춰 봅니다.
- 같은 시간대에 RED의 요청 제한 시험은 하지 않습니다.
- 출발지 IP는 개인 채널로만 공유합니다.

## 준비 (한 번만)
```powershell
winget install k6 --source winget
k6 version
```

## 실행 (저장소 맨 위 폴더에서)
```powershell
cd D:\SafeTravel-EKS
# 시험해 보기 (WAF 제한 안쪽: 초당 1건, 30초)
k6 run -e BASE_URL=https://travelsafe.click -e LABEL=dryrun -e RATE=1 -e DURATION=30s tests/zero-downtime/keeper-zero-downtime.js

# 본 측정 (rate-limit 규칙이 Count로 바뀐 뒤에만). --out csv 가 요청별 시각 파일
k6 run --out csv=tests/zero-downtime/results/before-requests.csv -e BASE_URL=https://travelsafe.click -e LABEL=before tests/zero-downtime/keeper-zero-downtime.js 2>&1 | Tee-Object tests/zero-downtime/results/before-log.txt
k6 run --out csv=tests/zero-downtime/results/after-requests.csv  -e BASE_URL=https://travelsafe.click -e LABEL=after  tests/zero-downtime/keeper-zero-downtime.js 2>&1 | Tee-Object tests/zero-downtime/results/after-log.txt
```
- 주소는 **도메인(https://travelsafe.click)**으로 씁니다. ALB 주소(http)로 보내면 https로 넘어가면서 인증서 이름이 맞지 않아 전부 연결 실패가 납니다(11/24 미리 시험에서 확인).
- CSV의 `http_req_duration` 줄 하나가 요청 하나입니다. `timestamp`(유닉스 초)와 `status`, `name`(주소)으로 실패 시각을 찾습니다.

## 측정 전 확인 (13:50까지)
```powershell
# 파드가 모두 Running·Ready인지
kubectl -n keeper get pods
# ALB에 WAF가 붙어 있는지: 결과에 wafv2-acl-arn 이 보여야 함 (값은 기록하지 않음)
kubectl -n keeper get ingress keeper -o jsonpath="{.metadata.annotations}" | Select-String wafv2
# 사이트가 200인지
curl.exe -sI https://travelsafe.click | Select-String "HTTP/"
# 이 시각의 ALB IP 기록 (FAIL·INVALID 줄의 ip= 와 비교해 DNS 탓인지 서비스 탓인지 가름)
nslookup travelsafe.click 8.8.8.8
# 도메인이 EKS(nginx)로 가는지: Server: nginx 여야 함. AmazonS3·cloudfront가 보이면 DNS가 아직 옛 2.5차 사이트로 감 (11/24 발견)
curl.exe -4 -s -D - -o NUL https://travelsafe.click/ | Select-String "Server|Via"
```

## DNS와 실패 구분
- 도메인은 Route 53 **A 별칭(alias)** 레코드로 ALB에 연결됩니다(infra/dns.tf, CNAME 아님). 별칭은 TTL을 따로 정하지 않고 ALB 레코드의 TTL(60초)을 따릅니다.
- 재구축 때마다 ALB가 새로 생기고 별칭도 apply 마지막(앱 배포 뒤)에 다시 걸립니다. 하루 안에서는 ALB가 바뀌지 않으므로 **측정 중에 DNS가 바뀌지는 않습니다.** 재구축 직후 1~2분은 전날 ALB 주소가 남을 수 있어, 측정은 재구축 뒤 충분히 지나서 합니다.
- FAIL 줄의 `ip=`가 측정 전에 기록한 ALB IP와 같으면 서비스 문제, 다르면 DNS 문제입니다. EKS가 아닌 곳이 답하면 무효로 따로 셉니다.

## 11/25 순서 (늦어지면 같은 간격으로 밂)
restart 명령: `kubectl -n keeper rollout restart deployment/keeper-web deployment/keeper-api` (한 번에 web·api가 하나씩 교체됨).
1번만 하면 교체 구간에 들어가는 요청이 수십 건뿐이라 문제가 있어도 0건이 나올 수 있어서, 단계마다 3번 합니다(SOC 의견).
| 시각 | 할 일 | 누가 |
| --- | --- | --- |
| 13:55 | WAF rate-limit 규칙 Block → Count, 변경 기록 시트에 기록 | 조장, SOC |
| 14:00~14:10 | **Before**: k6 시작 → restart **3번** (14:03, 14:06, 14:09) → 14:10 k6 종료 | WEB, 조장 |
| 14:10 | 차트 PR 병합 → 자동 배포(빌드·Trivy·helm upgrade) | 조장 |
| 배포가 끝나고 파드가 모두 Ready | `kubectl -n keeper rollout status deployment/keeper-web` (api·vault도) 완료 확인 후 시작 시각 공유 | 조장, WEB |
| 그때부터 10분 | **After**: k6 시작(T) → restart 3번 (T+3, T+6, T+9분) → T+10 k6 종료 | WEB, 조장 |
| 14:35 | rate-limit 규칙 Count → Block 복구 | 조장 |
| 끝난 뒤 | 결과(요청 수·실패 수·응답 시간·실제 시작/종료 시각) 공유 | WEB → SOC |

## 결과
`results/<LABEL>-summary.txt`(사람이 읽는 요약), `<LABEL>-summary.json`(전체 수치), `<LABEL>-log.txt`(실행 화면, FAIL 줄에 실패 시각).
실패 시각과 restart 시각, SOC 로그를 맞춰 보면 어느 순간에 끊겼는지 알 수 있습니다.
