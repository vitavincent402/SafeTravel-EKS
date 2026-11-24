variable "region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "name" {
  description = "리소스 이름 앞에 붙는 이름"
  type        = string
  default     = "keeper"
}

variable "domain_name" {
  description = "서비스 도메인(호스팅 영역 이름). 영역은 이 이름으로 만들어진다"
  type        = string
  default     = "travelsafe.click"
}

variable "web_hosts" {
  description = "화면 주소(호스트 이름) 목록. 돌아올 주소·로그아웃 주소를 이 호스트마다 만든다"
  type        = list(string)
  default     = ["travelsafe.click", "www.travelsafe.click"]
}

variable "callback_paths" {
  description = "로그인 후 돌아올 경로. 화면 담당과 정한 값: /auth/callback.html"
  type        = list(string)
  default     = ["/auth/callback.html"]
}

variable "logout_paths" {
  description = "로그아웃 후 돌아올 경로"
  type        = list(string)
  default     = ["/"]
}

variable "extra_callback_urls" {
  description = "위 규칙으로 만들어지지 않는 돌아올 주소 (예: 개발용 http://localhost:8080/callback.html)"
  type        = list(string)
  default     = []
}

variable "extra_logout_urls" {
  description = "위 규칙으로 만들어지지 않는 로그아웃 주소"
  type        = list(string)
  default     = []
}

variable "enable_ses_domain" {
  description = "서울 SES에 도메인 ID(Easy DKIM)를 만들고 DKIM CNAME 3개를 호스팅 영역에 넣는다"
  type        = bool
  default     = true
}

variable "cognito_use_ses" {
  description = "Cognito 메일을 SES로 보낼지. SES 운영 발송 권한(샌드박스 해제)이 확인된 뒤에만 true. false면 Cognito 기본 발송"
  type        = bool
  default     = false
}

variable "cognito_managed_login_version" {
  description = "관리형 로그인 화면 버전: 1(클래식) 또는 2(새 관리형 로그인)"
  type        = number
  default     = 1

  validation {
    condition     = contains([1, 2], var.cognito_managed_login_version)
    error_message = "1 또는 2만 쓸 수 있습니다."
  }
}
