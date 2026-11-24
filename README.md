# SafeTravel Keeper — 3차 프로젝트

`terraform apply` 한 번으로 AWS 인프라와 EKS 클러스터를 만들고, 마지막 단계에서 GitHub Actions 파이프라인을 실행해 앱(web·api·vault)까지 배포합니다.

## 폴더 구조

```
infra/                      Terraform (WAS: VPC·EKS·데이터·WAF / SOC: IAM·애드온·bootstrap)
  versions.tf               provider 설정
  variables.tf              입력 값
  vpc.tf                    VPC, 서브넷 3종(퍼블릭·프라이빗·데이터), NAT 1개
  eks.tf                    EKS, 노드 그룹, VPC CNI(NetworkPolicy 켬), GitHub 역할 접근 권한, keeper 네임스페이스
  data.tf                   KMS, S3, RDS(+보안 그룹), Secrets Manager
  ecr.tf                    ECR 저장소 4개 (이미지 3 + Helm 차트 1)
  iam.tf                    GitHub OIDC 역할, 파드별 IRSA 역할(api, vault)
  waf.tf                    WAF (AWS 관리형 규칙 + 요청 횟수 제한)
  dns.tf                    ACM 인증서, Route 53 레코드 (도메인 있을 때만)
  addons.tf                 AWS Load Balancer Controller
  bootstrap.tf              apply 마지막 단계: 파이프라인 실행·대기 / destroy 첫 단계: 앱 삭제
  security.tf               보안 기준선: 입장 정책 4종 + kube-bench 정기 점검 (charts/security-baseline)
  outputs.tf
charts/keeper/              Helm 차트 (SOC: 골격 / DB: 앱 값)
  templates/apps.yaml       web·api·vault 각각 ServiceAccount + Deployment + Service
  templates/ingress.yaml    ALB, WAF·HTTPS 연결
  templates/networkpolicy.yaml  기본 거부 + 허용 경로 5개
apps/web, apps/api, apps/vault  임시 앱 (각 담당이 실제 코드로 교체)
.github/workflows/deploy.yml    빌드 → Trivy → ECR → Helm 패키지 → helm upgrade
tests/attack/               위험 파드 예시 4종 (서버 dry-run 전용, 모두 거부되어야 정상)
scripts/security-check.ps1  보안 자체 점검 20항목 → evidence/ 에 결과 저장
```

## 처음 한 번 준비

1. GitHub 저장소(비공개)에 이 폴더를 main 브랜치로 push (이미 되어 있으면 생략)
2. 실행할 PC에 설치: Terraform 1.6 이상, AWS CLI v2, GitHub CLI, Helm 3
   - Windows는 PowerShell(VS Code 터미널)에서 그대로 실행됩니다. `bootstrap.tf`가 실행 PC를 보고 PowerShell/bash 스크립트를 고릅니다.
   - 확인: `terraform version`, `aws --version`, `gh --version`, `helm version`
   - GitHub 로그인: `gh auth login` (HTTPS, 브라우저 로그인). `gh auth status`에 `Token scopes`에 `repo`, `workflow`가 있어야 합니다.
3. Terraform 실행용 IAM 사용자로 로그인 (루트 계정으로 apply하지 않음)
   ```powershell
   aws configure --profile keeper          # IAM 사용자 액세스 키 입력, 리전 ap-northeast-2, 출력 json
   $env:AWS_PROFILE = "keeper"             # 터미널을 새로 열 때마다. terraform·kubectl·helm이 모두 이 프로필을 씀
   aws sts get-caller-identity             # Arn 끝이 user/keeper-netsec 인지 확인
   ```
   - `apply`를 실행한 IAM 사용자가 클러스터 관리자가 됩니다. 다른 사람이 apply하면 관리자가 바뀌므로, state를 S3로 옮기기 전까지 apply는 한 사람만 합니다.
4. `cp infra/terraform.tfvars.example infra/terraform.tfvars` (PowerShell: `Copy-Item`). `github_repo`는 이미 채워져 있습니다.

## 비용 (크레딧만 쓰기)

- 켜 두면 하루 7~8달러 안팎입니다(EKS 컨트롤 플레인, 노드 2대, NAT, RDS, ALB). 크레딧이 끝나면 카드로 청구됩니다.
- **작업이 끝나는 날에는 반드시 `terraform destroy`.** 다음 날 `terraform apply`로 다시 만듭니다.
- 도메인(`domain_name`)은 비워 두세요. 도메인 등록비는 크레딧으로 결제되지 않습니다.
- `cluster_version`은 표준 지원 버전만 쓰고, `cluster_upgrade_policy = STANDARD`로 연장 지원 추가 요금을 막아 둡니다.

## 구축과 삭제

```bash
cd infra
terraform init
terraform apply        # 20~30분. run_bootstrap_deploy = true 이므로 끝나면 앱까지 떠 있음
terraform output app_url

terraform destroy      # 앱 삭제 → ALB 정리 → 인프라 삭제 순서로 자동 진행
```

구축 후 `main`에 push하면(apps/, charts/ 변경) 파이프라인이 자동으로 다시 배포합니다.

## 각자 앱 코드를 넣을 때 지켜야 할 것

- 포트는 8080, `/healthz`가 200을 돌려줘야 함 (ALB·쿠버네티스 상태 검사)
- api는 `/api/...` 경로로 받음 (Ingress가 `/api`를 api로 보냄)
- 이미지는 **root가 아닌 숫자 사용자**로 실행 (`USER 10001`). keeper 네임스페이스는 Pod Security `restricted`라서 root 파드는 거부됨
- 파일 쓰기는 `/tmp`만 가능 (루트 파일 시스템 읽기 전용)
- 비밀번호는 코드나 Git에 넣지 말고, 환경 변수 `DB_SECRET_ARN`·`APP_SECRET_ARN`의 위치에서 AWS SDK로 읽기
- Trivy가 HIGH·CRITICAL 취약점(수정 버전이 있는 것)을 찾으면 배포가 중단됨 → 베이스 이미지·라이브러리 버전을 올려서 해결

## 확인이 필요한 것 (실제 계정에서 첫 apply 때)

- `cluster_version`(1.35, 2026-11 기준 표준 지원)과 RDS `engine_version`(16)이 구축 시점에 지원되는지
- Load Balancer Controller 3.6.3: 차트와 IAM 정책 주소 확인됨 (2026-11-23)
- 계정에 GitHub OIDC 공급자가 이미 있으면 `create_github_oidc_provider = false`
- 도메인을 쓰면 Route 53 호스팅 영역이 먼저 있어야 함

이 코드는 `terraform validate`와 `helm lint`·`helm template`까지만 확인했고, 실제 AWS 계정에서 apply는 아직 해 보지 않았습니다.

## 보안 점검

멘토 키트(hannctl_mentoring)의 s3·s4·s5 시나리오에서 우리 구조에 없던 통제를 가져와 적용했습니다.

| 통제 | 위치 | 출처 |
|---|---|---|
| 노드 IMDSv2 + hop limit 1, 노드 디스크 암호화 | `infra/eks.tf` | s4·s5 `cfn/stack.yaml` |
| EKS 감사 로그(audit·api·authenticator) 명시 | `infra/eks.tf` | s4 감사 로그 |
| default ServiceAccount 토큰 자동 마운트 끔 | `infra/eks.tf` | s4 CIS 4.1.5 |
| 입장 정책: privileged·hostPath·root 금지, 우리 ECR 이미지만 허용 | `infra/charts/security-baseline` | `_shared/k8s/kyverno-baseline.yaml`, s3 `trusted-registry.yaml` |
| kube-bench(CIS EKS) 정기 점검 CronJob | `infra/charts/security-baseline` | s4 `kube-bench-cronjob.yaml` |
| Trivy 버전 고정 | `.github/workflows/deploy.yml` | s3 CI 예시 |
| 위험 파드 dry-run 예시 | `tests/attack/` | 각 시나리오 `k8s/attack` |
| 보안 자체 점검 스크립트 | `scripts/security-check.ps1` | s4 `checks/cluster_checks.py` |

입장 정책은 멘토 키트의 Kyverno 정책과 같은 CEL 식을 쓰되, 쿠버네티스 내장 기능(ValidatingAdmissionPolicy)으로 적용해 추가 파드·웹훅 없이 동작합니다.

```powershell
$env:AWS_PROFILE = "keeper"
powershell -ExecutionPolicy Bypass -File scripts\security-check.ps1      # 20항목 점검 → evidence\
kubectl create job kb-now --from=cronjob/kube-bench-daily -n security-audit   # CIS 점검 즉시 실행
kubectl logs job/kb-now -n security-audit
```

## Before / After 시연 (보안 통제 켜기·끄기)

`hardening` 변수로 일부 통제를 끈 상태와 켠 상태를 같은 점검으로 비교합니다. **기본값은 `true`(전부 적용)**이고, `false`는 Before 시연 때만 씁니다. 평가·실제 서비스용 구축은 `false`로 만들지 마세요.

| 통제 | hardening=false (Before) | hardening=true (After) | 점검 |
|---|---|---|---|
| 파드 보안(PSA restricted) | 끔 | 강제 | S01 |
| default NetworkPolicy(기본 거부) | 없음 | 있음 | S03 |
| 입장 정책 4종 | 없음 | 있음 | S04 |
| default SA 토큰 자동 마운트 | 켬 | 끔 | S05 |
| 위험 파드 4종(dry-run) | 생성 허용 | 거부 | S07~S10 |
| kube-bench 정기 점검 | 없음 | 있음 | S11 |
| WAF 연결 | 없음 | 연결 | S13 |
| EKS 감사 로그 | 꺼짐 | 켜짐 | S14 |
| 노드 IMDS | v1 허용, hop 2 | v2 필수, hop 1 | S16 |
| 팀원 권한 등급 | 모두 관리자 | 각자 level(최소 권한) | S20 |

스위치에 넣지 않은 통제(RDS 암호화, S3 공개 차단, ECR 설정 등 S17~S19, RBAC S02·S06, 공개 엔드포인트 S15)는 Before에서도 그대로입니다. RDS 암호화는 켜고 끄려면 DB를 새로 만들어야 하고, 나머지는 끄는 것 자체가 위험하기 때문입니다.

```powershell
cd infra
$env:AWS_PROFILE = "keeper"

# 1) Before: 통제를 끈 채로 구축 (앱까지 배포됨)
terraform apply -var hardening=false
cd ..
powershell -ExecutionPolicy Bypass -File scripts\security-check.ps1 -Label before

# 2) After: 같은 클러스터에서 통제를 켬 (노드가 교체되어 10~20분 걸림, 앱은 다시 배포됨)
cd infra
terraform apply
cd ..
powershell -ExecutionPolicy Bypass -File scripts\security-check.ps1 -Label after

# 3) 두 결과를 나란히 비교 (evidence\before-after-<시각>.md 저장)
powershell -ExecutionPolicy Bypass -File scripts\compare-checks.ps1 -Before evidence\security-check-before-<시각>.csv -After evidence\security-check-after-<시각>.csv
```

`hardening=false`로 구축한 클러스터는 일부 통제가 꺼져 있으니 점검이 끝나면 바로 `terraform apply`(true)로 되돌리거나 삭제하세요.
