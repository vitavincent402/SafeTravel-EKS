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
  outputs.tf
charts/keeper/              Helm 차트 (SOC: 골격 / DB: 앱 값)
  templates/apps.yaml       web·api·vault 각각 ServiceAccount + Deployment + Service
  templates/ingress.yaml    ALB, WAF·HTTPS 연결
  templates/networkpolicy.yaml  기본 거부 + 허용 경로 5개
apps/web, apps/api, apps/vault  임시 앱 (각 담당이 실제 코드로 교체)
.github/workflows/deploy.yml    빌드 → Trivy → ECR → Helm 패키지 → helm upgrade
```

## 처음 한 번 준비

1. GitHub 저장소를 만들고 이 폴더를 main 브랜치에 push
2. 실행할 PC에 설치: Terraform 1.6 이상, AWS CLI v2, GitHub CLI(`gh auth login`), Helm 3, bash
   - Windows는 PowerShell에서 그대로 실행됩니다. `bootstrap.tf`가 실행 PC를 보고 PowerShell/bash 스크립트를 고릅니다.
   - PowerShell에서는 `export` 대신 `$env:AWS_PROFILE = "keeper"`, `-target`은 `'-target=module.vpc'`처럼 작은따옴표로 감쌉니다.
3. Terraform 실행용 IAM 사용자로 로그인 (루트 계정으로 apply하지 않음)
   ```bash
   aws configure --profile keeper      # IAM 사용자 액세스 키 입력, 리전 ap-northeast-2
   export AWS_PROFILE=keeper           # 터미널을 새로 열 때마다. terraform·kubectl·helm이 모두 이 프로필을 씀
   aws sts get-caller-identity         # Arn이 ...:user/<본인 IAM 사용자> 인지 확인
   ```
   - `apply`를 실행한 IAM 사용자가 클러스터 관리자가 됩니다. 다른 사람이 apply하면 관리자가 바뀌므로, S3 state로 옮기기 전까지 apply는 한 사람만 합니다.
4. `cp infra/terraform.tfvars.example infra/terraform.tfvars` 후 `github_repo` 채우기

## 첫 구축: 단계별로 (인프라만, 파이프라인 없이)

`terraform.tfvars`에서 `run_bootstrap_deploy = false`인 상태로 진행합니다. 실패하면 그 단계만 다시 실행합니다.

```bash
cd infra
terraform init
terraform apply -target=module.vpc     # 약 3분
terraform apply -target=module.eks     # 약 15~20분
terraform apply                        # 나머지 (RDS·S3·KMS·ECR·WAF·LB Controller), 약 10~15분

aws eks update-kubeconfig --name keeper-eks --region ap-northeast-2
kubectl get nodes                      # 노드 2대 Ready
kubectl get pods -n kube-system        # aws-load-balancer-controller Running
kubectl get ns keeper --show-labels    # pod-security.kubernetes.io/enforce=restricted

terraform destroy                      # 작업이 끝난 날에는 삭제 (켜 두면 하루 7~8달러 안팎)
```

`-target` 경고는 정상입니다. 파이프라인이 준비되면 `run_bootstrap_deploy = true`로 바꿔 아래 "구축과 삭제"를 한 번에 확인합니다.

## 구축과 삭제

```bash
cd infra
terraform init
terraform apply        # 20~30분. 끝나면 앱까지 떠 있음
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
