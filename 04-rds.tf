# ==============================================================================
# REFERENCE ONLY: RDS Database (Commented out because MongoDB Atlas is used)
# ==============================================================================
# If you ever need a relational database (PostgreSQL/MySQL) in the future,
# uncomment the blocks below.
# ==============================================================================

/*
# 1. DB Subnet Group (Placing RDS inside Private Data Subnets)
resource "aws_db_subnet_group" "rds" {
  name        = "microservices-rds-subnet-group"
  subnet_ids  = aws_subnet.private_data[*].id
  description = "Subnet group for RDS database in private data subnets"

  tags = {
    Name = "microservices-rds-subnet-group"
  }
}

# 2. RDS Instance Example
# Note: Terraform resource blocks create new infrastructure. If an RDS database
# already exists with the name 'microservices-db', Terraform would fail with a duplicate name error.
# To import an existing DB into Terraform instead of creating a new one, you would run:
# terraform import aws_db_instance.postgres microservices-db

resource "aws_db_instance" "postgres" {
  identifier            = "microservices-db"
  allocated_storage     = 20
  max_allocated_storage = 50
  engine                = "postgres"
  engine_version        = "15"
  instance_class        = "db.t3.micro"
  
  db_name               = "microservices_db"
  username              = "dbadmin"
  password              = "InitialPass123!" # In production, use AWS Secrets Manager

  db_subnet_group_name   = aws_db_subnet_group.rds.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  publicly_accessible   = false
  skip_final_snapshot   = true

  tags = {
    Name = "microservices-postgres"
  }
}

output "rds_endpoint" {
  description = "Connection endpoint for the RDS Instance"
  value       = aws_db_instance.postgres.endpoint
}
*/

# ==============================================================================
# MONGODB ATLAS NOTE
# ==============================================================================
# MongoDB Atlas is hosted outside this VPC on MongoDB's cloud.
# Workloads in your EKS private subnets will route outbound through the NAT Gateway
# (01-vpc.tf) and use the Security Group 'MongoDB-SG' (02-security-groups.tf).
# The connection string (e.g. mongodb+srv://...) will be securely injected 
# into AWS Secrets Manager in Step 12.