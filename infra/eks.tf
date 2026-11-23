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
    # 조회만
    viewer = {
      view = {
        policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
        access_scope = { type = "cluster", namespaces = [] }
      }
    }
  }

  team_access_entries = {
    for name, m in var.team_members : name => {
      principal_arn       = m.arn
      policy_associations = local.access_levels[m.level]
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
    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
    }
  }

  depends_on = [module.eks]
}
