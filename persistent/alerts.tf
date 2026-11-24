# 알림 주제 (SNS) — 가용성 감시(infra/monitoring.tf)의 알람이 여기로 보낸다.   [WEB 담당]
# 메인 스택에서 매일 새로 만들면 구독 확인 메일을 매일 다시 눌러야 해서, 지워지지 않는 이 폴더에 한 번만 만든다.
# 메일 주소는 terraform.tfvars 에만 적고 Git 에 올리지 않는다.
# 알람 내용(어느 확인이 실패했는지)만 담겨 비밀값이 없으므로 KMS 암호화는 쓰지 않는다.
# (KMS로 암호화하면 CloudWatch 알람이 보낼 수 있게 키 정책을 따로 열어야 함)

variable "alert_email" {
  description = "가용성 감시 알림을 받을 이메일. 비우면 주제만 만들고 구독은 만들지 않는다. 처음 apply 뒤 받은 메일에서 Confirm subscription 을 한 번 누른다"
  type        = string
  default     = ""
}

resource "aws_sns_topic" "alerts" {
  name = "${var.name}-alerts"
}

resource "aws_sns_topic_subscription" "alerts_email" {
  count     = var.alert_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}
