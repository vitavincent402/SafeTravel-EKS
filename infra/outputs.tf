output "cluster_name" {
  value = module.eks.cluster_name
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}"
}

output "ecr_registry" {
  value = local.ecr_registry
}

output "github_actions_role_arn" {
  value = aws_iam_role.github_actions.arn
}

output "app_url" {
  value = local.use_domain ? "https://${var.domain_name}" : "도메인 없음: kubectl get ingress -n keeper 로 ALB 주소 확인"
}

output "app_urls" {
  description = "접속 주소 전체 (대표 + 추가 주소)"
  value       = [for d in local.all_domains : "https://${d}"]
}

output "hardening" {
  description = "보안 통제 상태. false면 Before 시연용으로 일부 통제가 꺼져 있음"
  value       = var.hardening
}
