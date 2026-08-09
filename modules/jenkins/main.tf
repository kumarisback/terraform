resource "aws_iam_role" "this" {
  name = "${var.name}-${var.environment}-jenkins-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })

  tags = merge(local.common_tags, {
    Name = "${var.name}-${var.environment}-jenkins-role"
  })
}

resource "aws_iam_role_policy_attachment" "ecr" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
}

resource "aws_iam_role_policy_attachment" "terraform_state" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

resource "aws_iam_instance_profile" "this" {
  name = "${var.name}-${var.environment}-jenkins-profile"
  role = aws_iam_role.this.name
}

resource "aws_security_group" "this" {
  name        = "${var.name}-${var.environment}-jenkins-sg"
  description = "Allow Jenkins access"
  vpc_id      = var.vpc_id

  ingress {
    description = "Jenkins UI"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.name}-${var.environment}-jenkins-sg"
  })
}

data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

locals {
  common_tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
    Project     = var.name
  }
}

resource "aws_instance" "jenkins" {
  ami                         = var.ami_id != "" ? var.ami_id : data.aws_ami.amazon_linux_2023.id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.this.id]
  iam_instance_profile        = aws_iam_instance_profile.this.name
  associate_public_ip_address = true

  user_data = <<-EOF
#!/bin/bash
set -euxo pipefail

# =========================================================
# System update
# =========================================================

dnf update -y

# =========================================================
# Basic tools
# =========================================================

dnf install -y \
  git \
  wget \
  unzip \
  tar \
  gzip \
  jq \
  zip \
  which \
  ca-certificates \
  openssl \
  java-21-amazon-corretto

# =========================================================
# Java 21 and Python
# =========================================================

alternatives --set java /usr/lib/jvm/java-21-amazon-corretto.x86_64/bin/java

dnf install -y python3 python3-pip

# Install Checkov for Terraform security scanning
pip3 install --upgrade pip
pip3 install checkov

# =========================================================
# Docker
# =========================================================

dnf install -y docker

systemctl enable docker
systemctl start docker

# Jenkins and ec2-user can use Docker without sudo
usermod -aG docker jenkins || true
usermod -aG docker ec2-user || true

# =========================================================
# Node.js 22 LTS
# =========================================================

curl -fsSL https://rpm.nodesource.com/setup_22.x | bash -

dnf install -y nodejs

# =========================================================
# AWS CLI v2
# =========================================================

curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" \
  -o "/tmp/awscliv2.zip"

unzip -q /tmp/awscliv2.zip -d /tmp

/tmp/aws/install

rm -rf /tmp/aws /tmp/awscliv2.zip

# =========================================================
# Terraform
# =========================================================

TERRAFORM_VERSION="1.12.2"

curl -fsSL \
  "https://releases.hashicorp.com/terraform/$${TERRAFORM_VERSION}/terraform_$${TERRAFORM_VERSION}_linux_amd64.zip" \
  -o /tmp/terraform.zip

unzip -o /tmp/terraform.zip -d /usr/local/bin

chmod +x /usr/local/bin/terraform

rm -f /tmp/terraform.zip

# =========================================================
# kubectl
# =========================================================

KUBECTL_VERSION="$(curl -L -s https://dl.k8s.io/release/stable.txt)"

curl -LO "https://dl.k8s.io/release/$${KUBECTL_VERSION}/bin/linux/amd64/kubectl"

install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

rm -f kubectl

# =========================================================
# Helm
# =========================================================

curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# =========================================================
# Jenkins repository
# =========================================================

wget -O /etc/yum.repos.d/jenkins.repo \
  https://pkg.jenkins.io/redhat-stable/jenkins.repo

rpm --import https://pkg.jenkins.io/rpm-stable/jenkins.io-2026.key

# =========================================================
# Jenkins
# =========================================================

dnf install -y jenkins

# Make sure Jenkins uses Java 21
alternatives --set java /usr/lib/jvm/java-21-amazon-corretto.x86_64/bin/java

# =========================================================
# Jenkins permissions
# =========================================================

usermod -aG docker jenkins
usermod -aG docker ec2-user

# =========================================================
# Start Jenkins
# =========================================================

systemctl daemon-reload

systemctl enable jenkins
systemctl start jenkins

# =========================================================
# Display installed versions in cloud-init log
# =========================================================

echo "===== Java ====="
java -version

echo "===== Node ====="
node --version

echo "===== npm ====="
npm --version

echo "===== Git ====="
git --version

echo "===== Docker ====="
docker --version

echo "===== AWS CLI ====="
aws --version

echo "===== Terraform ====="
terraform version

echo "===== kubectl ====="
kubectl version --client

echo "===== Helm ====="
helm version

echo "===== Jenkins ====="
systemctl status jenkins --no-pager || true

echo "===== Jenkins installation completed ====="

EOF

  tags = merge(local.common_tags, {
    Name = "${var.name}-${var.environment}-jenkins"
  })
}
