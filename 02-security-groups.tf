# 1. Security Group for RDS (PostgreSQL / MySQL)
resource "aws_security_group" "rds" {
  name        = "Database-SG"
  description = "Allow database traffic from within the VPC"
  vpc_id      = aws_vpc.main.id

  # Ingress for PostgreSQL (Port 5432) from VPC CIDR
  ingress {
    description = "PostgreSQL access from VPC"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }

  # Ingress for MySQL (Port 3306) from VPC CIDR
  ingress {
    description = "MySQL access from VPC"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "Database-SG"
  }
}

# 2. Security Group for ElastiCache Redis
resource "aws_security_group" "redis" {
  name        = "Redis-SG"
  description = "Allow Redis traffic from within the VPC"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Redis access from VPC"
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "Redis-SG"
  }
}

# 3. Security Group for MongoDB (Standard Port 27017)
resource "aws_security_group" "mongodb" {
  name        = "MongoDB-SG"
  description = "Allow MongoDB traffic from within the VPC"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "MongoDB access from VPC"
    from_port   = 27017
    to_port     = 27017
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }

  # Allows workloads in EKS/VPC to connect outbound to MongoDB Atlas URL
  egress {
    description = "Allow all outbound traffic to external MongoDB Atlas"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "MongoDB-SG"
  }
}