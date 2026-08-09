pipeline {
  agent any

  parameters {
    choice(name: 'ENVIRONMENT', choices: ['dev', 'staging', 'prod'], description: 'Target environment')
  }

  environment {
    TERRAFORM_DIR = 'infrastructure/app-cluster'
    ENV_DIR = '../../environments/app-cluster'
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
          sh "terraform init -backend-config=${ENV_DIR}/${params.ENVIRONMENT}-backend.hcl"
        }
      }
    }

    stage('Terraform Format Check') {
      steps {
        sh 'terraform fmt -check -recursive'
      }
    }

    // stage('Security Scan (Checkov)') {
    //   steps {
    //     dir(TERRAFORM_DIR) {
    //       sh "checkov -d . --var-file ${ENV_DIR}/${params.ENVIRONMENT}.tfvars --skip-check CKV_AWS_20"
    //     }
    //   }
    // }

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
          sh "terraform plan -var-file=${ENV_DIR}/${params.ENVIRONMENT}.tfvars -out=tfplan"
        }
      }
    }

    stage('Terraform Apply') {
      when {
        branch 'main'
      }
      steps {
        dir(TERRAFORM_DIR) {
          sh "terraform apply -auto-approve tfplan"
        }
      }
    }
  }
}
