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
  description = "팀원의 클러스터 권한. 키는 이름, arn은 IAM 사용자 ARN, level은 admin | developer | viewer | tester(조회 + keeper 네임스페이스 파드 생성만, RED용)"
  type = map(object({
    arn   = string
    level = string
  }))
  default = {}

  validation {
    condition     = alltrue([for m in values(var.team_members) : contains(["admin", "developer", "viewer", "tester"], m.level)])
    error_message = "level은 admin, developer, viewer, tester 중 하나여야 합니다."
  }
}

variable "sa_guard_deny" {
  description = "앱 서비스 어카운트(keeper-*) 도용 방지 정책을 거부(Deny)로 켤지. false(기본)=Warn+Audit만(검증 기간). 정상 배포가 걸리지 않는 것을 확인한 뒤 true"
  type        = bool
  default     = false
}

variable "rate_limit" {
  description = "WAF rate-limit 규칙의 한도. 한 IP가 5분 동안 보낼 수 있는 요청 수(WAF 최소 10). 화면 폴링과 공용망(한 IP에 여러 명)을 고려해 기본 1000"
  type        = number
  default     = 1000

  validation {
    condition     = var.rate_limit >= 100 && var.rate_limit <= 20000000
    error_message = "rate_limit은 100 이상이어야 합니다."
  }
}

variable "rate_limit_action" {
  description = "WAF rate-limit 규칙의 동작. block(기본) 또는 count(차단하지 않고 집계만). count는 부하 측정 시간에만 쓰고 끝나면 block으로 되돌린다"
  type        = string
  default     = "block"

  validation {
    condition     = contains(["block", "count"], var.rate_limit_action)
    error_message = "rate_limit_action은 block 또는 count 중 하나여야 합니다."
  }
}

variable "waf_extra_rules_action" {
  description = "2.5차에서 가져온 추가 WAF 규칙 5개(blocked-method, blocked-path, nested-encoding, known-bad-inputs, ip-reputation)의 동작. count(기본, 집계만) 또는 block. Count 로그를 보고 정상 요청이 걸리지 않는지 확인한 뒤 block으로 바꾼다"
  type        = string
  default     = "count"

  validation {
    condition     = contains(["count", "block"], var.waf_extra_rules_action)
    error_message = "waf_extra_rules_action은 count 또는 block 중 하나여야 합니다."
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
