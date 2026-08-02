# ==============================================================================
# 1. IAM Role & Instance Profile for Jenkins EC2
# ==============================================================================
resource "aws_iam_role" "jenkins_role" {
  name = "jenkins-ec2-ecr-role"

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
}

# Attach ECR PowerUser Policy so Jenkins can log in, build, and push images
resource "aws_iam_role_policy_attachment" "jenkins_ecr_policy" {
  role       = aws_iam_role.jenkins_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
}

resource "aws_iam_instance_profile" "jenkins_profile" {
  name = "jenkins-ec2-instance-profile"
  role = aws_iam_role.jenkins_role.name
}

# ==============================================================================
# 2. Security Group for Jenkins (HTTP 8080 & SSH 22)
# ==============================================================================
resource "aws_security_group" "jenkins_sg" {
  name        = "jenkins-security-group"
  description = "Allow inbound traffic for Jenkins and SSH"
  vpc_id      = aws_vpc.main.id # References your VPC module from 01-vpc.tf

  ingress {
    description = "Jenkins UI"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH Access"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Change to your IP for tighter security
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "jenkins-sg"
  }
}

# ==============================================================================
# 3. Amazon Linux 2023 AMI Lookup
# ==============================================================================
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

# ==============================================================================
# 4. EC2 Instance with UserData Bootstrap Script
# ==============================================================================
resource "aws_instance" "jenkins_server" {
  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = "t3.medium" # Recommended for running Jenkins + Docker builds
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.jenkins_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.jenkins_profile.name

  # Automatically installs Docker, Jenkins, Git & AWS CLI on boot
  user_data = <<-EOF
              #!/bin/bash
              sudo yum update -y

              # Install Docker & Git
              sudo dnf install -y docker git
              sudo systemctl start docker
              sudo systemctl enable docker

              # Install Jenkins
              sudo wget -O /etc/yum.repos.d/jenkins.repo https://pkg.jenkins.io/redhat-stable/jenkins.repo
              sudo rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io-2026.key
              sudo dnf install -y java-17-amazon-corretto jenkins
              sudo systemctl daemon-reload
              sudo systemctl enable jenkins
              sudo systemctl start jenkins

              # Add jenkins user to docker group so Jenkins can run 'docker build/push'
              sudo usermod -aG docker jenkins
              sudo usermod -aG docker ec2-user
              sudo systemctl restart jenkins
              EOF

  tags = {
    Name = "jenkins-server"
  }
}

# ==============================================================================
# 5. Outputs
# ==============================================================================
output "jenkins_public_ip" {
  value       = aws_instance.jenkins_server.public_ip
  description = "Public IP to access Jenkins UI"
}

output "jenkins_url" {
  value       = "http://${aws_instance.jenkins_server.public_ip}:8080"
  description = "URL to open Jenkins in your browser"
}
