locals {
  name       = "taskflow-dev"
  aws_region = var.aws_region
}

data "aws_caller_identity" "current" {}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${local.name}-vpc"
  cidr = "10.20.0.0/16"

  azs             = ["${local.aws_region}a", "${local.aws_region}b", "${local.aws_region}c"]
  public_subnets  = ["10.20.101.0/24", "10.20.102.0/24", "10.20.103.0/24"]

  enable_nat_gateway = false
  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  map_public_ip_on_launch = true
}

module "ecr_backend" {
  source  = "terraform-aws-modules/ecr/aws"
  version = "~> 2.0"
  repository_name                  = "taskflow-backend"
  repository_image_tag_mutability  = "MUTABLE"
  repository_encryption_type       = "KMS"
  create_lifecycle_policy          = false
}

module "ecr_frontend" {
  source  = "terraform-aws-modules/ecr/aws"
  version = "~> 2.0"
  repository_name                  = "taskflow-frontend"
  repository_image_tag_mutability  = "MUTABLE"
  repository_encryption_type       = "KMS"
  create_lifecycle_policy          = false
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name                    = "${local.name}-eks"
  cluster_version                 = "1.30"
  enable_irsa                     = true
  cluster_endpoint_public_access  = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.public_subnets

  # Grant current IAM user cluster-admin via aws-auth
  access_entries = {
    admin = {
      principal_arn    = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/terraform-user"
      kubernetes_groups = ["eks-admins"]
      policy_associations = {
        cluster_admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }

  eks_managed_node_groups = {
    default = {
      min_size       = 1
      max_size       = 2
      desired_size   = 1
      instance_types = ["t3.small"]
      capacity_type  = "ON_DEMAND"

      labels = {
        "capacity-type" = "on-demand"
      }

      subnet_ids = module.vpc.public_subnets
    }
    
    spot_general = {
      min_size       = 0
      max_size       = 3
      desired_size   = 0
      instance_types = ["t3.medium", "t3.large", "m5.large", "c5.large"]
      capacity_type  = "SPOT"

      labels = {
        "capacity-type" = "spot"
      }

      subnet_ids = module.vpc.public_subnets
    }
  }
}

output "cluster_name" { value = module.eks.cluster_name }
output "ecr_backend_repo_url" { value = module.ecr_backend.repository_url }
output "ecr_frontend_repo_url" { value = module.ecr_frontend.repository_url }
output "vpc_id" { value = module.vpc.vpc_id }


