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
- 요청 속도: 기본 초당 5건. **WAF 요청 제한(IP당 5분 300건 = 초당 1건)** 때문에, 측정 시간에는 조장이 rate-limit 규칙을 Count로 바꿔 둡니다(전환 13:55, 복구 14:35).
  그 밖의 시간에 돌릴 때는 `RATE=1`, 짧게(1분 이하)만 돌립니다.
- 403이 모두 합쳐 5건이 되면 WAF에 걸린 것으로 보고 시험을 스스로 멈춥니다.
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

# 본 측정 (rate-limit 규칙이 Count로 바뀐 뒤에만)
k6 run -e BASE_URL=https://travelsafe.click -e LABEL=before tests/zero-downtime/keeper-zero-downtime.js 2>&1 | Tee-Object tests/zero-downtime/results/before-log.txt
k6 run -e BASE_URL=https://travelsafe.click -e LABEL=after  tests/zero-downtime/keeper-zero-downtime.js 2>&1 | Tee-Object tests/zero-downtime/results/after-log.txt
```
HTTPS가 아직이면 `BASE_URL`에 `http://<ALB 주소>`를 넣습니다.

## 11/25 순서 (늦어지면 같은 간격으로 밂)
| 시각 | 할 일 | 누가 |
| --- | --- | --- |
| 13:55 | WAF rate-limit 규칙 Block → Count, 변경 기록 시트에 기록 | 조장, SOC |
| 14:00~14:10 | **Before**: k6 시작 → 14:03 `kubectl -n keeper rollout restart deployment/keeper-web deployment/keeper-api` → 14:10 종료 | WEB, 조장 |
| 14:10 | 차트 PR 병합 → 자동 배포(helm upgrade). 배포가 끝난 것을 확인 | 조장 |
| 배포 끝난 뒤 10분 | **After**: k6 시작 → 3분 뒤 restart → 10분에 종료 | WEB, 조장 |
| 14:35 | rate-limit 규칙 Count → Block 복구 | 조장 |
| 끝난 뒤 | 결과(요청 수·실패 수·응답 시간·실제 시작/종료 시각) 공유 | WEB → SOC |

## 결과
`results/<LABEL>-summary.txt`(사람이 읽는 요약), `<LABEL>-summary.json`(전체 수치), `<LABEL>-log.txt`(실행 화면, FAIL 줄에 실패 시각).
실패 시각과 restart 시각, SOC 로그를 맞춰 보면 어느 순간에 끊겼는지 알 수 있습니다.
