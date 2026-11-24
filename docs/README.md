# 문서·자료 폴더

역할별로 폴더가 나뉘어 있습니다. 본인 역할 폴더에 문서, 그림, 발표 자료, 테스트 결과를 올리세요.

| 폴더 | 역할 | 코드 위치 |
|---|---|---|
| `was/` | VPC·EKS Terraform, 트래픽 정책(보안 그룹·NetworkPolicy·WAF) | `infra/` |
| `db/` | api, vault, Helm 앱 값 | `apps/api/`, `apps/vault/`, `charts/keeper/` |
| `soc/` | 애드온, CI/CD, IAM·bootstrap | `.github/workflows/`, `infra/addons.tf`, `infra/iam.tf`, `infra/bootstrap.tf` |
| `web/` | web 화면, 문서 통합 | `apps/web/` |
| `red/` | 공격 테스트 계획과 결과 | (코드 없음) |
| `common/` | 아키텍처 그림 2종, 통합 문서 초안 | |

## 올리는 방법

main 브랜치는 보호되어 있어서 바로 push할 수 없습니다. 브랜치를 만들어 올린 뒤 Pull Request를 열고, 저장소 관리자의 승인을 받으면 반영됩니다.

```
git switch -c 브랜치이름
git add docs/본인역할폴더
git commit -m "무엇을 올렸는지"
git push -u origin 브랜치이름
```

그다음 GitHub 저장소 페이지에서 **Compare & pull request**를 누릅니다.

## 올리면 안 되는 것

- 비밀번호, 액세스 키, 토큰, `terraform.tfvars`, `terraform.tfstate`
- 실제 신분증·여권 사진이나 실제 개인정보 (테스트 데이터는 가짜로 만든 것만)
- AWS 계정 번호가 들어 있는 화면 캡처 (가리고 올리기)

## 규칙

- 파일 이름은 영문 소문자와 숫자, `-`를 권장합니다. (예: `network-diagram.png`)
- 사람 이름 대신 역할 이름(WAS, DB, SOC, WEB, RED)을 씁니다.
- 큰 파일(영상 등)은 올리지 말고 링크를 적어 두세요.
