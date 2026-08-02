pipeline {
  agent any

  environment {
    TERRAFORM_DIR = 'environments/dev'
  }

  stages {
    stage('Checkout') {
      steps {
        checkout scm
      }
    }

    stage('Terraform Init') {
      steps {
        dir(TERRAFORM_DIR) {
          sh 'terraform init -backend=false'
        }
      }
    }

    stage('Terraform Format Check') {
      steps {
        sh 'terraform fmt -check -recursive'
      }
    }

    stage('Terraform Validate') {
      steps {
        dir(TERRAFORM_DIR) {
          sh 'terraform validate'
        }
      }
    }

    stage('Terraform Plan') {
      steps {
        dir(TERRAFORM_DIR) {
          sh 'terraform plan -var-file=terraform.tfvars -input=false'
        }
      }
    }
  }
}
