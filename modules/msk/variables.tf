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

variable "client_security_group_ids" {
  description = "Security groups allowed to connect (port 9098): the EKS cluster security group, which the nodes and their pods carry"
  type        = list(string)

  validation {
    condition     = length(var.client_security_group_ids) > 0
    error_message = "Name at least one client security group: with none, nothing could connect."
  }
}
