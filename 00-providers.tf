# Configure the AWS Provider
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Environment = "Development"
      ManagedBy   = "Terraform"
      Project     = "Microservices"
    }
  }
}

# Variable for Region flexibility
variable "aws_region" {
  type        = string
  default     = "us-east-1"
  description = "AWS Region to deploy resources into"
}