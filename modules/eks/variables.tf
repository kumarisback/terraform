variable "name" {
  description = "Base name for EKS resources"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for EKS nodes"
  type        = list(string)
}

variable "cluster_version" {
  description = "EKS cluster version"
  type        = string
  default     = "1.36"
}

variable "endpoint_public_access" {
  description = "Whether to expose the EKS Kubernetes API endpoint publicly."
  type        = bool
  default     = false
}

variable "public_access_cidrs" {
  description = "CIDR blocks allowed to reach the public EKS Kubernetes API endpoint."
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.public_access_cidrs, "0.0.0.0/0")
    error_message = "Do not expose the EKS API endpoint to 0.0.0.0/0. Use your public IP/VPN CIDR instead."
  }
}

variable "node_desired_capacity" {
  description = "Desired number of worker nodes"
  type        = number
  default     = 2
}

variable "node_min_capacity" {
  description = "Minimum number of worker nodes"
  type        = number
  default     = 1
}

variable "node_max_capacity" {
  description = "Maximum number of worker nodes"
  type        = number
  default     = 5
}

variable "node_instance_type" {
  description = "EC2 instance type for worker nodes"
  type        = string
  default     = "t3.medium"
}

variable "admin_users" {
  description = "Additional IAM User ARNs to grant admin access to the EKS cluster"
  type        = list(string)
  default     = []
}

variable "node_capacity_type" {
  description = "Capacity type for the node group: ON_DEMAND or SPOT"
  type        = string
  default     = "ON_DEMAND"

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.node_capacity_type)
    error_message = "node_capacity_type must be ON_DEMAND or SPOT."
  }
}

variable "node_disk_size" {
  description = "Root EBS volume size (GiB) for worker nodes"
  type        = number
  default     = 20
}

variable "node_update_max_unavailable" {
  description = "Max number of nodes unavailable during a node group rolling update"
  type        = number
  default     = 1
}

variable "node_labels" {
  description = "Kubernetes labels to apply to nodes in this node group"
  type        = map(string)
  default     = {}
}

variable "node_taints" {
  description = "Kubernetes taints to apply to nodes in this node group"
  type = list(object({
    key    = string
    value  = string
    effect = string
  }))
  default = []
}

variable "irsa_roles" {
  description = "IRSA roles to create for in-cluster controllers, keyed by a short name (e.g. \"external_secrets\", \"aws_lb_controller\"). Each entry creates one IAM role trusting this cluster's OIDC provider for the given namespace/service account."
  type = map(object({
    namespace          = string
    service_account    = string
    policy_arns        = optional(list(string), [])
    inline_policy_json = optional(string)
  }))
  default = {}
}
