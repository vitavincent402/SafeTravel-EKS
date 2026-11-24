# Route 53 호스팅 영역 (프로젝트 계정). 매일 destroy 대상 밖에 한 번만 만든다.
# 만든 뒤 출력된 이름 서버 4개를 도메인 등록 계정의 도메인 이름 서버로 바꿔야 DNS가 이 영역을 본다.
resource "aws_route53_zone" "this" {
  name    = var.domain_name
  comment = "SafeTravel Keeper (persistent layer)"

  lifecycle {
    prevent_destroy = true
  }
}
