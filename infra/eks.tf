# hardening 변수: false면 Before 시연용으로 감사 로그, IMDS 제한, 팀원 권한 등급, PSA, default SA 토큰 설정을 끈 채로 만듭니다.
# 기본값은 true(전부 적용)입니다. 순서와 점검 방법은 README의 "Before / After 시연"을 보세요.
# 팀원 권한 (var.team_members). IAM 사용자는 이 코드 밖에서 만들고(매일 destroy해도 유지),
# 여기서는 클러스터 안 권한(access entry)만 부여합니다.
locals {
  access_levels = {
    # 클러스터 전체 관리 (인프라 담당)
    admin = {
      cluster_admin = {
        policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
        access_scope = { type = "cluster", namespaces = [] }
      }
    }
    # 전체 조회 + keeper 네임스페이스 안에서만 수정 (앱·DB·CI/CD 담당)
    developer = {
      view = {
        policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
        access_scope = { type = "cluster", namespaces = [] }
      }
      keeper_edit = {
        policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"
        access_scope = { type = "namespace", namespaces = ["keeper"] }
      }
    }
    # 조회 + keeper 네임스페이스 쓰기(Secret 조회 제외). Edit 정책 대신 security-baseline의 Role을 쓴다.
    developer-nosecret = {
      view = {
        policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
        access_scope = { type = "cluster", namespaces = [] }
      }
    }
    # 조회만
    viewer = {
      view = {
        policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
        access_scope = { type = "cluster", namespaces = [] }
      }
    }
    # 조회 + keeper 네임스페이스에 파드 '만들기'만 (RED 공격 시험용). 아래 access_groups의 그룹이 Role로 연결됨.
    # 시험하는 파드는 입장 정책에서 거부되는 것을 확인하는 용도이고, Secret 조회·exec·삭제·수정 권한은 없음
    tester = {
      view = {
        policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
        access_scope = { type = "cluster", namespaces = [] }
      }
    }
  }

  # level별로 붙일 쿠버네티스 그룹 (차트 security-baseline의 pod-tester Role이 이 그룹에 묶임)
  pod_tester_group         = "keeper-pod-tester"
  developer_nosecret_group = "keeper-developer-nosecret"
  access_groups = {
    tester             = [local.pod_tester_group]
    developer-nosecret = [local.developer_nosecret_group]
  }

  team_access_entries = {
    for name, m in var.team_members : name => {
      # hardening=false(Before 시연)에서는 모두 관리자, true에서는 각자의 level(최소 권한)
      principal_arn       = m.arn
      policy_associations = local.access_levels[var.hardening ? m.level : "admin"]
      kubernetes_groups   = lookup(local.access_groups, var.hardening ? m.level : "admin", [])
    }
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.24"

  cluster_name    = "${var.project}-eks"
  cluster_version = var.cluster_version

  # 표준 지원 기간이 끝나도 추가 요금이 붙는 연장 지원으로 넘어가지 않게 고정 (크레딧을 아끼기 위해)
  cluster_upgrade_policy = {
    support_type = "STANDARD"
  }

  # GitHub Actions(인터넷)에서 helm upgrade를 하려면 API 엔드포인트가 공개되어 있어야 합니다.
  # 접속은 IAM 인증을 통과한 역할만 가능하고, GitHub 역할은 keeper 네임스페이스 권한만 받습니다.
  cluster_endpoint_public_access = true

  # 감사 로그: 누가 클러스터 API에 무엇을 요청했는지 CloudWatch Logs에 남깁니다 (CIS EKS 2.1.1).
  # 모듈 기본값과 같지만 코드에서 보이도록 명시하고, 보존 기간만 90일 → 7일로 줄였습니다(비용).
  # 로그 그룹은 destroy 때 같이 지워지므로, 증적이 필요하면 destroy 전에 내보내세요.
  cluster_enabled_log_types              = var.hardening ? ["api", "audit", "authenticator"] : []
  cloudwatch_log_group_retention_in_days = 7

  # terraform apply를 실행한 사람(역할)에게 클러스터 관리자 권한
  enable_cluster_creator_admin_permissions = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  enable_irsa = true

  cluster_addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni = {
      before_compute = true
      # 이 설정이 없으면 NetworkPolicy 객체를 만들어도 아무것도 막지 않습니다.
      configuration_values = jsonencode({
        enableNetworkPolicy = "true"
      })
    }
  }

  eks_managed_node_groups = {
    default = {
      # Amazon Linux 2 노드 이미지는 1.32까지만 나오므로 AL2023을 명시합니다.
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = ["t3.medium"]
      min_size       = 2
      max_size       = 3
      desired_size   = 2

      # IMDSv2 강제 + hop limit 1: 파드가 노드의 메타데이터(169.254.169.254)에 접근해
      # 노드 IAM 역할 자격 증명을 훔치는 경로를 막습니다. 파드는 IRSA로 자기 역할만 받습니다.
      # (모듈 기본값은 hop limit 2 → 파드에서도 노드 자격 증명이 보임)
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = var.hardening ? "required" : "optional"
        http_put_response_hop_limit = var.hardening ? 1 : 2
      }

      # 노드 디스크 암호화
      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 20
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }
    }
  }

  # GitHub Actions 역할: keeper 네임스페이스 안에서만 배포 가능
  access_entries = merge(
    {
      github_actions = {
        principal_arn = aws_iam_role.github_actions.arn
        policy_associations = {
          keeper_edit = {
            policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"
            access_scope = {
              type       = "namespace"
              namespaces = ["keeper"]
            }
          }
        }
      }
    },
    local.team_access_entries
  )
}

# 앱 네임스페이스. Pod Security 'restricted'를 강제해 root 파드·권한 상승 파드는 거부됩니다.
resource "kubernetes_namespace" "keeper" {
  metadata {
    name = "keeper"
    labels = var.hardening ? {
      "pod-security.kubernetes.io/enforce" = "restricted"
    } : {}
  }

  depends_on = [module.eks]
}

# keeper 네임스페이스의 default ServiceAccount는 API 토큰을 자동으로 붙이지 않음 (CIS EKS 4.1.5)
# 앱은 차트에서 만든 전용 ServiceAccount(keeper-web/api/vault)를 씁니다.
resource "kubernetes_default_service_account_v1" "keeper" {
  metadata {
    namespace = kubernetes_namespace.keeper.metadata[0].name
  }
  automount_service_account_token = !var.hardening
}
