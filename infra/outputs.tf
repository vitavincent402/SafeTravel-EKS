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
