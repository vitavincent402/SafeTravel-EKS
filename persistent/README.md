# persistent — 매일 destroy 대상 밖에 한 번만 만드는 것

메인 스택(`infra/`)은 매일 `terraform destroy` 합니다. 아래는 지우면 곤란하거나 지울 때마다 바뀌면 안 되는 것이라 **별도 폴더·별도 state**로 한 번만 만듭니다.

| 리소스 | 이유 |
|---|---|
| Route 53 호스팅 영역 `travelsafe.click` | 이름 서버 4개를 도메인 등록 계정에 한 번 넣으면 끝. 지우고 다시 만들면 이름 서버가 바뀌어 매번 다시 넣어야 함 |
| SES 도메인 ID + DKIM CNAME 3개 | 도메인 확인(Verified)을 매일 다시 기다리지 않기 위해 |
| Cognito 사용자 풀·앱 클라이언트·로그인 도메인 | 회원 계정은 지우면 복구할 수 없음. 삭제 보호(`ACTIVE`)와 `prevent_destroy` |
| 알림 주제(SNS) `keeper-alerts` + 이메일 구독 | 매일 새로 만들면 구독 확인 메일을 매일 다시 눌러야 함. 가용성 감시(`infra/monitoring.tf`)가 출력 `alert_topic_arn`으로 받아 씀 |

메인 스택은 이 영역을 이름(`hosted_zone_name`)으로 찾아 쓰고, Cognito는 출력값 3개를 `terraform.tfvars`에 넣어 받습니다. 그래서 `infra/` 의 `destroy`는 이 폴더의 것을 건드리지 않습니다.

## 처음 한 번만

```powershell
cd D:\SafeTravel-EKS\keeper\persistent
$env:AWS_PROFILE = "keeper"
terraform init
terraform plan        # Plan: N to add, 0 to destroy 확인
terraform apply
terraform output
```

1. **이름 서버 바꾸기** — 출력 `name_servers` 4개를 도메인 등록 계정(도메인 소유자)에서 `travelsafe.click`의 이름 서버로 입력한다. 바뀐 뒤 퍼지는 데 수 분~수 시간 걸린다. 확인: `nslookup -type=NS travelsafe.click`
2. **SES DKIM** — CNAME 3개는 이 폴더가 새 영역에 자동으로 만든다. 예전 영역에서 옮기지 않는다. (DKIM 토큰은 SES ID를 새로 만들 때마다 달라서, 옮긴 값은 맞지 않는다.) 이름 서버가 바뀐 뒤 SES 콘솔에서 `Verified`가 되는지 확인한다.
3. **메인 스택에 값 넣기** — `infra/terraform.tfvars`에
   ```hcl
   domain_name          = "travelsafe.click"
   hosted_zone_name     = "travelsafe.click"
   extra_domain_names   = ["www.travelsafe.click"]
   cognito_user_pool_id = "<출력 cognito_user_pool_id>"
   cognito_client_id    = "<출력 cognito_client_id>"
   cognito_login_domain = "<출력 cognito_login_domain>"
   alert_topic_arn      = "<출력 alert_topic_arn>"   # 가용성 감시를 켤 때
   ```
   알림 메일은 `persistent/terraform.tfvars`의 `alert_email`에 적고 apply한 뒤, 받은 메일에서 **Confirm subscription**을 한 번 누른다.
   이름 서버가 바뀌기 전에 `infra/`를 apply하면 인증서 DNS 검증이 끝나지 않아 apply가 오래 멈춘다. **이름 서버 변경이 퍼진 뒤에** 한다.

## 값을 바꿀 때

- 돌아올 경로가 정해지면 `callback_paths` / `logout_paths`를 바꿔 `apply` (앱 클라이언트만 제자리 수정, 회원 정보 영향 없음)
- Cognito `schema`(email, name 속성)는 만든 뒤 바꾸면 풀이 새로 만들어져 회원이 사라진다. 바꾸지 않는다.
- SES로 메일을 보내려면 서울 SES 운영 발송 권한(샌드박스 해제)이 필요하다. 확인된 뒤 `cognito_use_ses = true`

## 지우고 싶을 때 (프로젝트가 끝났을 때)

`prevent_destroy`와 Cognito 삭제 보호가 막는다. 의도적으로 지우려면 `cognito.tf`·`zone.tf`·`ses.tf`의 `prevent_destroy`를 `false`로, `deletion_protection`을 `"INACTIVE"`로 바꿔 `apply`한 뒤 `terraform destroy`. 호스팅 영역은 레코드가 남아 있으면 지워지지 않는다.

## state를 S3로 (infra/ 상태 파일 공유)

`state.tf`가 상태 파일 보관용 S3 버킷(`keeper-tfstate-<계정 번호>`: 버전 관리, 암호화, 퍼블릭 차단, HTTPS만 허용, 삭제 방지)을 만든다. 이 폴더를 `apply`하면 버킷만 추가된다.

`infra/`의 state를 옮기는 순서(destroy가 끝나 state가 비었을 때가 안전):

1. 이 폴더에서 `terraform apply` → 출력 `tfstate_bucket` 확인
2. `terraform version`이 1.10 이상인지 확인 (S3 잠금 파일 기능)
3. `infra/backend.tf.example`을 `backend.tf`로 이름을 바꾸고 `bucket`을 출력값으로 수정
4. `infra/`에서 `terraform init -migrate-state` → 물으면 `yes`
5. 로컬 `terraform.tfstate`는 백업 폴더로 옮겨 둔다. 그 뒤 `plan`이 이전과 같은지 확인

이 폴더(persistent/)의 state는 계속 로컬 파일이다. 버킷을 만드는 쪽이 자기 버킷에 의존하지 않게 하려는 것이고, 백업은 계속 필요하다.

## 알아 둘 점

- state는 이 폴더의 `terraform.tfstate`(로컬, Git에 올리지 않음)다. 이 파일을 잃으면 이 리소스들을 Terraform이 관리하지 못한다. 백업해 둔다.
- 강사 조건("코드 한 번에 모든 것 구성")과의 관계: 이 폴더는 계정·도메인·로그인처럼 한 번 준비해 두는 선행 자원이고, 환경(EKS·앱)은 `infra/`의 `terraform apply` 한 번으로 만들어진다. 발표 때 이 구분과 이유(회원 정보·도메인 설정이 매일 사라지면 안 됨)를 설명한다.
