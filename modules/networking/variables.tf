variable "name" {
  description = "Base name for the infrastructure"
  type        = string
}

variable "environment" {
  description = "Environment name such as dev, staging, or prod"
  type        = string
}

variable "cidr_block" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_app_subnet_cidrs" {
  description = "CIDR blocks for private application subnets"
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24"]
}

variable "private_data_subnet_cidrs" {
  description = "CIDR blocks for private data subnets"
  type        = list(string)
  default     = ["10.0.21.0/24", "10.0.22.0/24"]
}

variable "availability_zones" {
  description = "Optional list of availability zones"
  type        = list(string)
  default     = []
}

variable "enable_nat_gateway" {
  description = "Whether to create a NAT gateway"
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = "If true (default), create one NAT gateway in the first public subnet, shared by all private subnets across every AZ — cheaper, but ties every AZ's outbound traffic to a single AZ's NAT. If false, create one NAT gateway (and one private route table) per AZ for high availability; requires private_app_subnet_cidrs and private_data_subnet_cidrs to have the same length as public_subnet_cidrs."
  type        = bool
  default     = true
}

variable "public_subnet_tags" {
  description = "Additional tags for the public subnets — e.g. kubernetes.io/role/elb and kubernetes.io/cluster/<name>, required for the AWS Load Balancer Controller's subnet auto-discovery to find them."
  type        = map(string)
  default     = {}
}

variable "private_subnet_tags" {
  description = "Additional tags for the private application subnets — e.g. kubernetes.io/role/internal-elb and kubernetes.io/cluster/<name>, required for the AWS Load Balancer Controller's subnet auto-discovery to find them."
  type        = map(string)
  default     = {}
}
