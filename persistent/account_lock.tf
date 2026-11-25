# SOC 승인 -> SQS FIFO -> 잠금 Lambda(VPC 밖) -> Cognito 계정 비활성화/해제.
# 2.5차(SafeTravel-Serverless/was_account_lock.tf, lambda_account_lock/handler.py)에서 만든 것을 keeper의 Cognito 풀에 맞춰 옮긴 것.
# persistent/에 두는 이유: Cognito 풀과 SOC 읽기 역할이 persistent/에 있고, 대기열 URL이 매일 바뀌면 SOC가 매번 다시 설정해야 한다.
# 기본은 꺼짐(만들지 않음). 켜는 순서: 팀 합의 -> enable_account_lock=true(persistent/terraform.tfvars) -> plan 공유 -> apply -> 대기열 URL을 SOC에 전달.
# 비용: SQS·Lambda·CloudWatch 모두 무료 구간 안(요청 수 극소). SOC에는 Cognito 쓰기 권한을 주지 않고, 쓰기는 Lambda만 한다.
# 안전장치: admin 그룹 계정은 잠그지 않는다(refused_admin). 대기열에 보낼 수 있는 주체는 SOC 서버 역할 한 곳뿐이다.
variable "enable_account_lock" {
  description = "true면 계정 잠금 대기열·Lambda를 만든다. 기본 false"
  type        = bool
  default     = false
}

variable "soc_lock_sender_role_arn" {
  description = "잠금 대기열에 SendMessage할 수 있는 SOC 서버 역할 ARN(정확히 한 개). 비우면 soc_reader_trusted_arn(SOC 서버 역할)을 쓴다"
  type        = string
  default     = ""

  validation {
    condition = var.soc_lock_sender_role_arn == "" ? true : can(regex(
      "^arn:aws:iam::[0-9]{12}:role/([A-Za-z0-9+=,.@_-]+/)*[A-Za-z0-9+=,.@_-]+$", var.soc_lock_sender_role_arn,
    ))
    error_message = "정확한 IAM 역할 ARN을 쓰세요."
  }
}

locals {
  account_lock        = var.enable_account_lock ? { enabled = true } : {}
  account_lock_sender = var.soc_lock_sender_role_arn != "" ? var.soc_lock_sender_role_arn : var.soc_reader_trusted_arn
}

# 압축 파일은 코드(lambda_account_lock/)에서 만들어 .build/에 둔다(저장소에는 올리지 않음)
data "archive_file" "account_lock" {
  type        = "zip"
  source_dir  = "${path.module}/lambda_account_lock"
  output_path = "${path.module}/.build/account_lock.zip"
}

resource "aws_cloudwatch_log_group" "account_lock" {
  for_each          = local.account_lock
  name              = "/aws/lambda/${var.name}-account-lock"
  retention_in_days = 30
}

resource "aws_sqs_queue" "account_lock_dlq" {
  for_each                  = local.account_lock
  name                      = "${var.name}-account-lock-dlq.fifo"
  fifo_queue                = true
  sqs_managed_sse_enabled   = true
  message_retention_seconds = 1209600
}

resource "aws_sqs_queue" "account_lock" {
  for_each                    = local.account_lock
  name                        = "${var.name}-account-lock.fifo"
  fifo_queue                  = true
  content_based_deduplication = false # SOC가 MessageDeduplicationId를 직접 지정: 잠금=request_id, 해제=request_id:unlock
  sqs_managed_sse_enabled     = true
  visibility_timeout_seconds  = 180
  message_retention_seconds   = 345600
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.account_lock_dlq["enabled"].arn
    maxReceiveCount     = 3
  })
}

resource "aws_sqs_queue_policy" "account_lock" {
  for_each  = var.enable_account_lock && local.account_lock_sender != "" ? { enabled = true } : {}
  queue_url = aws_sqs_queue.account_lock["enabled"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "SocServerSendOnly"
      Effect    = "Allow"
      Principal = { AWS = local.account_lock_sender }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.account_lock["enabled"].arn
    }]
  })
}

resource "aws_iam_role" "account_lock" {
  for_each    = local.account_lock
  name        = "${var.name}-account-lock-role"
  description = "SOC가 승인한 Cognito 계정 잠금/해제 (대기열 소비자)"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy" "account_lock" {
  for_each = local.account_lock
  name     = "${var.name}-account-lock"
  role     = aws_iam_role.account_lock["enabled"].name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.account_lock["enabled"].arn}:*"
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = aws_sqs_queue.account_lock["enabled"].arn
      },
      {
        Effect = "Allow"
        Action = [
          "cognito-idp:AdminGetUser", "cognito-idp:AdminListGroupsForUser", "cognito-idp:AdminDisableUser",
          "cognito-idp:AdminEnableUser", "cognito-idp:AdminUserGlobalSignOut",
        ]
        Resource = aws_cognito_user_pool.users.arn
      },
    ]
  })
}

resource "aws_lambda_function" "account_lock" {
  for_each         = local.account_lock
  function_name    = "${var.name}-account-lock"
  description      = "SOC가 승인한 Cognito 계정 잠금(SQS 소비자, VPC 밖)"
  role             = aws_iam_role.account_lock["enabled"].arn
  filename         = data.archive_file.account_lock.output_path
  source_code_hash = data.archive_file.account_lock.output_base64sha256
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  architectures    = ["x86_64"]
  memory_size      = 128
  timeout          = 30

  environment {
    variables = { USER_POOL_ID = aws_cognito_user_pool.users.id }
  }
  logging_config {
    log_group  = aws_cloudwatch_log_group.account_lock["enabled"].name
    log_format = "Text"
  }
  depends_on = [aws_iam_role_policy.account_lock]
}

resource "aws_lambda_event_source_mapping" "account_lock" {
  for_each                = local.account_lock
  event_source_arn        = aws_sqs_queue.account_lock["enabled"].arn
  function_name           = aws_lambda_function.account_lock["enabled"].arn
  batch_size              = 1
  function_response_types = ["ReportBatchItemFailures"]
}

output "account_lock_queue_url" {
  description = "SOC 서버가 잠금 요청을 보낼 대기열 URL (enable_account_lock=true일 때만)"
  value       = var.enable_account_lock ? aws_sqs_queue.account_lock["enabled"].url : null
}
