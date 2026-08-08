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
  set -e

  # Update system
  dnf update -y

  # Install Docker, Git, and Java 21
  dnf install -y docker git java-21-amazon-corretto

  # Start and enable Docker
  systemctl enable docker
  systemctl start docker

  # Install Jenkins repository
  wget -O /etc/yum.repos.d/jenkins.repo \
    https://pkg.jenkins.io/redhat-stable/jenkins.repo

  rpm --import https://pkg.jenkins.io/rpm-stable/jenkins.io-2026.key

  # Install Jenkins
  dnf install -y jenkins

  # Make sure Jenkins uses Java 21
  alternatives --set java /usr/lib/jvm/java-21-amazon-corretto.x86_64/bin/java

  # Allow Jenkins and ec2-user to use Docker
  usermod -aG docker jenkins
  usermod -aG docker ec2-user

  # Enable and start Jenkins
  systemctl daemon-reload
  systemctl enable jenkins
  systemctl start jenkins
EOF

  tags = merge(local.common_tags, {
    Name = "${var.name}-${var.environment}-jenkins"
  })
}
