pipeline {
  agent any

  parameters {
    choice(name: 'ENVIRONMENT', choices: ['dev', 'staging', 'prod'], description: 'Target environment')
    choice(name: 'ACTION', choices: ['apply', 'destroy'], description: 'Action to perform: apply or destroy')
  }

  environment {
    TERRAFORM_DIR = 'infrastructure/app-cluster'
    ENV_DIR       = "${WORKSPACE}/environments/app-cluster"
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
          script {
            if (params.ACTION == 'destroy') {
              sh "terraform plan -destroy -var-file=${ENV_DIR}/${params.ENVIRONMENT}.tfvars -out=tfplan"
            } else {
              sh "terraform plan -var-file=${ENV_DIR}/${params.ENVIRONMENT}.tfvars -out=tfplan"
            }
          }
        }
      }
    }

    stage('Manual Approval') {
      steps {
        script {
          if (params.ACTION == 'destroy') {
            input message: "⚠️ DANGER: Confirm DESTROYing environment '${params.ENVIRONMENT}'?", ok: 'DESTROY ALL'
          } else {
            input message: "Approve Terraform Apply for environment '${params.ENVIRONMENT}'?", ok: 'Apply'
          }
        }
      }
    }

    stage('Terraform Execute') {
      steps {
        dir(TERRAFORM_DIR) {
          // Applying a saved plan file (tfplan) executes exact planned changes (apply or destroy)
          sh "terraform apply tfplan"
        }
      }
    }
  }

  post {
    always {
      // Clean up local plan file and workspace
      dir(TERRAFORM_DIR) {
        sh 'rm -f tfplan'
      }
      cleanWs()
    }
  }
}