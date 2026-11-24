variable "region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "project" {
  description = "리소스 이름 앞에 붙는 이름"
  type        = string
  default     = "keeper"
}

variable "cluster_version" {
  description = "EKS 쿠버네티스 버전. 표준 지원 중인 버전만 쓸 것 (연장 지원 버전은 클러스터 시간당 추가 요금)"
  type        = string
  # 2026-11 기준 표준 지원: 1.34(12/2 종료)·1.35·1.36·1.37. 프로젝트 기간 내내 표준 지원이고, 출시 후 10개월이 지나 애드온·차트가 대응하는 1.35 사용
  default = "1.35"
}

variable "github_repo" {
  description = "배포 파이프라인이 있는 GitHub 저장소 (owner/repo)"
  type        = string
}

variable "create_github_oidc_provider" {
  description = "계정에 GitHub OIDC 공급자가 이미 있으면 false"
  type        = bool
  default     = true
}

variable "domain_name" {
  description = "서비스 도메인 (예: keeper.example.com). 비워 두면 HTTPS 없이 ALB 주소로 접속"
  type        = string
  default     = ""
}

variable "extra_domain_names" {
  description = "대표 주소 외에 함께 쓸 주소 (예: [\"www.travelsafe.click\"]). 인증서·A 레코드·Ingress에 같이 들어간다. 모두 hosted_zone_name 영역 안의 이름이어야 함"
  type        = list(string)
  default     = []
}

variable "hosted_zone_name" {
  description = "Route 53 호스팅 영역 이름 (예: example.com). domain_name을 쓸 때만 필요"
  type        = string
  default     = ""
}

variable "run_bootstrap_deploy" {
  description = "apply 마지막에 GitHub Actions 배포를 실행하고 끝날 때까지 기다릴지"
  type        = bool
  default     = true
}

variable "github_oidc_sub_prefix" {
  description = "GitHub OIDC sub 값의 앞부분. 비우면 repo:<github_repo>. 저장소가 불변 주체(immutable subject)를 쓰면 gh api repos/<repo>/actions/oidc/customization/sub 의 sub_claim_prefix 값을 넣는다."
  type        = string
  default     = ""
}

variable "team_members" {
  description = "팀원의 클러스터 권한. 키는 이름, arn은 IAM 사용자 ARN, level은 admin | developer | viewer"
  type = map(object({
    arn   = string
    level = string
  }))
  default = {}

  validation {
    condition     = alltrue([for m in values(var.team_members) : contains(["admin", "developer", "viewer"], m.level)])
    error_message = "level은 admin, developer, viewer 중 하나여야 합니다."
  }
}

variable "hardening" {
  description = "보안 통제를 켤지. true(기본)=전부 적용. false=Before 시연용으로 일부 통제를 끈 채 구축하고 점검한 뒤, true로 다시 apply해 After를 점검. 실제 서비스·평가용 구축은 반드시 true"
  type        = bool
  default     = true
}

# 로그인(Cognito). 풀은 persistent/ 에서 한 번만 만들고, 여기에는 그 출력값을 넣는다.
variable "cognito_user_pool_id" {
  description = "persistent/ 가 만든 Cognito 사용자 풀 ID (출력 cognito_user_pool_id). 비워 두면 앱에 전달하지 않음"
  type        = string
  default     = ""
}

variable "cognito_client_id" {
  description = "persistent/ 가 만든 앱 클라이언트 ID (출력 cognito_client_id)"
  type        = string
  default     = ""
}

variable "cognito_login_domain" {
  description = "관리형 로그인 주소 (출력 cognito_login_domain, https://...amazoncognito.com)"
  type        = string
  default     = ""
}
