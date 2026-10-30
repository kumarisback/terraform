variable "name" {
  description = "Base name for the MSK resources"
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

variable "subnet_ids" {
  description = "Subnets for the cluster's endpoints: two to five, each in a different availability zone"
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2 && length(var.subnet_ids) <= 5
    error_message = "MSK Serverless needs two to five subnets, in different availability zones."
  }
}

variable "client_cidr_blocks" {
  description = "CIDR blocks allowed to connect (port 9098): the subnets the pods get their addresses from"
  type        = list(string)
}
