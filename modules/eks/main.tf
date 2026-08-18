terraform {
  required_providers {
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

locals {
  common_tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
    Project     = var.name
  }
}

# EKS Cluster IAM Role
resource "aws_iam_role" "eks_cluster_role" {
  name = "${var.name}-${var.environment}-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name = "${var.name}-${var.environment}-eks-cluster-role"
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster_role.name
}

# EKS Node Group IAM Role
resource "aws_iam_role" "eks_node_role" {
  name = "${var.name}-${var.environment}-eks-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name = "${var.name}-${var.environment}-eks-node-role"
  })
}

resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_node_role.name
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks_node_role.name
}

resource "aws_iam_role_policy_attachment" "eks_ecr_read_only" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks_node_role.name
}

data "aws_vpc" "this" {
  id = var.vpc_id
}

resource "aws_security_group" "eks_cluster" {
  name        = "${var.name}-${var.environment}-eks-cluster-sg"
  description = "Security group for the EKS cluster"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.name}-${var.environment}-eks-cluster-sg"
  })
}

resource "aws_security_group_rule" "eks_cluster_ingress_vpc" {
  description       = "Allow inbound HTTPS traffic to EKS control plane from within the VPC"
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = [data.aws_vpc.this.cidr_block]
  security_group_id = aws_security_group.eks_cluster.id
}

resource "aws_security_group_rule" "eks_cluster_ingress_private" {
  count             = length(var.private_access_cidrs) > 0 ? 1 : 0
  description       = "Allow inbound HTTPS traffic to EKS control plane from peered network or VPN CIDRs"
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = var.private_access_cidrs
  security_group_id = aws_security_group.eks_cluster.id
}

resource "aws_eks_cluster" "this" {
  name     = "${var.name}-${var.environment}-eks-cluster"
  role_arn = aws_iam_role.eks_cluster_role.arn
  version  = var.cluster_version

  vpc_config {
    subnet_ids              = var.private_subnet_ids
    security_group_ids      = [aws_security_group.eks_cluster.id]
    endpoint_public_access  = var.endpoint_public_access
    public_access_cidrs     = var.endpoint_public_access ? var.public_access_cidrs : []
    endpoint_private_access = true
  }

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  tags = merge(local.common_tags, {
    Name = "${var.name}-${var.environment}-eks-cluster"
  })
}


# Launch template lets the node group enforce IMDSv2 and a configurable root
# volume size — neither is settable on aws_eks_node_group directly.
resource "aws_launch_template" "node" {
  name_prefix = "${var.name}-${var.environment}-eks-node-"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  # Nodes only ever launch into private subnets (var.private_subnet_ids), but
  # set this explicitly rather than relying on the subnet's default.
  network_interfaces {
    associate_public_ip_address = false
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.node_disk_size
      volume_type           = "gp3"
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(local.common_tags, {
      Name = "${var.name}-${var.environment}-eks-node"
    })
  }

  tags = merge(local.common_tags, {
    Name = "${var.name}-${var.environment}-eks-node-lt"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.name}-${var.environment}-eks-node-group"
  node_role_arn   = aws_iam_role.eks_node_role.arn
  subnet_ids      = var.private_subnet_ids
  capacity_type   = var.node_capacity_type

  scaling_config {
    desired_size = var.node_desired_capacity
    min_size     = var.node_min_capacity
    max_size     = var.node_max_capacity
  }

  update_config {
    max_unavailable = var.node_update_max_unavailable
  }

  launch_template {
    id      = aws_launch_template.node.id
    version = aws_launch_template.node.latest_version
  }

  instance_types = [var.node_instance_type]
  labels         = var.node_labels

  dynamic "taint" {
    for_each = var.node_taints
    content {
      key    = taint.value.key
      value  = taint.value.value
      effect = taint.value.effect
    }
  }

  tags = merge(local.common_tags, {
    Name = "${var.name}-${var.environment}-eks-node-group"
  })
}

resource "aws_eks_access_entry" "admins" {
  for_each      = toset(var.admin_users)
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "admins" {
  for_each      = toset(var.admin_users)
  cluster_name  = aws_eks_cluster.this.name
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  principal_arn = each.value

  access_scope {
    type = "cluster"
  }
}

# Read-only tier: same "front door" as admins, but capped to AmazonEKSViewPolicy
# instead of ClusterAdminPolicy. This is the non-admin path that didn't exist
# before — previously the only options were full cluster-admin or no access at all.
resource "aws_eks_access_entry" "viewers" {
  for_each      = toset(var.viewer_users)
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "viewers" {
  for_each      = toset(var.viewer_users)
  cluster_name  = aws_eks_cluster.this.name
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
  principal_arn = each.value

  access_scope {
    type = "cluster"
  }
}

# Custom tier: no AWS-managed policy at all. kubernetes_groups here is what
# makes the IAM principal's requests carry that group name to the API
# server's RBAC layer — it's the missing link that makes the ClusterRoleBindings
# in gitops/platform/rbac/ (subjects: kind: Group, name: "sre" / "developer-readonly")
# actually apply to someone. No aws_eks_access_policy_association is needed
# here because authorization is fully delegated to in-cluster RBAC instead of
# an AWS-managed access policy.
resource "aws_eks_access_entry" "group_mapped" {
  for_each          = var.group_mapped_users
  cluster_name      = aws_eks_cluster.this.name
  principal_arn     = each.key
  type              = "STANDARD"
  kubernetes_groups = each.value
}

# ---------------------------------------------------------
# IRSA (IAM Roles for Service Accounts)
#
# In-cluster controllers (External Secrets Operator, AWS Load Balancer
# Controller, etc.) need to call AWS APIs as a specific Kubernetes
# ServiceAccount, not as the node role. That requires an OIDC identity
# provider registered for this cluster's issuer, plus one IAM role per
# controller trusting that provider for a specific namespace/ServiceAccount.
# ---------------------------------------------------------

data "tls_certificate" "eks_oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks_oidc" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint]

  tags = merge(local.common_tags, {
    Name = "${var.name}-${var.environment}-eks-oidc"
  })
}

resource "aws_iam_role" "irsa" {
  for_each = var.irsa_roles

  name = "${var.name}-${var.environment}-irsa-${each.key}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = aws_iam_openid_connect_provider.eks_oidc.arn }
      Condition = {
        StringEquals = {
          "${replace(aws_iam_openid_connect_provider.eks_oidc.url, "https://", "")}:sub" = "system:serviceaccount:${each.value.namespace}:${each.value.service_account}"
          "${replace(aws_iam_openid_connect_provider.eks_oidc.url, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = merge(local.common_tags, {
    Name = "${var.name}-${var.environment}-irsa-${each.key}"
  })
}

resource "aws_iam_role_policy_attachment" "irsa_managed" {
  for_each = { for pair in flatten([
    for role_key, role in var.irsa_roles : [
      for policy_arn in role.policy_arns : { key = "${role_key}::${policy_arn}", role_key = role_key, policy_arn = policy_arn }
    ]
  ]) : pair.key => pair }

  role       = aws_iam_role.irsa[each.value.role_key].name
  policy_arn = each.value.policy_arn
}

resource "aws_iam_role_policy" "irsa_inline" {
  for_each = { for k, v in var.irsa_roles : k => v.inline_policy_json if v.inline_policy_json != null }

  name   = "${var.name}-${var.environment}-irsa-${each.key}-inline"
  role   = aws_iam_role.irsa[each.key].id
  policy = each.value
}
