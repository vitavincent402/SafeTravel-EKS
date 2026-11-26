# 클러스터 보안 기준선 (멘토 키트 hannctl_mentoring s3·s4의 정책과 점검을 우리 환경에 맞게 옮김)
#  1) 입장 정책(ValidatingAdmissionPolicy): keeper 네임스페이스에 위험한 파드가 만들어지기 전에 거부
#     - privileged / hostPath / root 실행 금지 (PSA restricted와 이중 방어)
#     - 우리 ECR(keeper/*) 이미지만 허용 → Trivy 게이트를 거치지 않은 이미지를 kubectl로 띄우는 우회를 차단
#  2) kube-bench(CIS Amazon EKS Benchmark) 정기 점검 CronJob
# 멘토 키트는 Kyverno를 쓰지만, 여기서는 쿠버네티스에 내장된 같은 기능(CEL 정책)을 써서
# 추가 파드와 웹훅 없이 적용합니다. destroy 때 웹훅이 남아 삭제를 막는 문제도 없습니다.
# 차트 파일을 고치면 charts/security-baseline/Chart.yaml의 version을 올려야 apply에 반영됩니다.
resource "helm_release" "security_baseline" {
  name      = "security-baseline"
  chart     = "${path.module}/charts/security-baseline"
  namespace = "kube-system"
  wait      = true

  values = [yamlencode({
    protectedNamespaces   = [kubernetes_namespace.keeper.metadata[0].name]
    trustedRegistryPrefix = "${local.ecr_registry}/keeper/"
    admissionPolicies     = { enabled = var.hardening }
    kubeBench             = { enabled = var.hardening }
    networkIsolation      = { enabled = var.hardening, apiServerCidrs = concat(local.private_subnets, ["${cidrhost(module.eks.cluster_service_cidr, 1)}/32"]) }
    podTester             = { enabled = true, group = local.pod_tester_group }
    # 앱 서비스 어카운트(keeper-*) 도용 방지. 처음에는 Warn+Audit(정상 배포가 안 걸리는지 확인), 검증 후 sa_guard_deny=true 로 거부 전환
    saGuard = {
      enabled = true
      actions = var.sa_guard_deny ? ["Deny"] : ["Warn", "Audit"]
      # 앱 서비스 어카운트를 쓸 수 있는 사용자: 배포 파이프라인(GitHub Actions 역할의 모든 세션)과 이 Terraform 실행 계정
      deployers = [
        "arn:aws:sts::${data.aws_caller_identity.current.account_id}:assumed-role/${aws_iam_role.github_actions.name}/",
        data.aws_caller_identity.current.arn,
      ]
    }
  })]

  depends_on = [module.eks, kubernetes_namespace.keeper]
}
