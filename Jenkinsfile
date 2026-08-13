pipeline {
  agent any

  parameters {
    choice(name: 'ENVIRONMENT', choices: ['dev', 'staging', 'prod'], description: 'Target environment')
    choice(name: 'ACTION', choices: ['apply', 'destroy'], description: 'Action to perform: apply or destroy')
  }

  environment {
    BASE_DIR = 'infrastructure/app-cluster'
    ENV_DIR  = "${WORKSPACE}/environments/app-cluster"
  }

  stages {
    stage('Checkout') {
      steps {
        checkout scm
      }
    }

    stage('Terraform Format Check') {
      steps {
        sh 'terraform fmt -check -recursive'
      }
    }

    // ==========================================
    // LAYER 1: INFRASTRUCTURE (VPC, EKS, RDS)
    // ==========================================
    stage('Layer 1: Init & Validate') {
      steps {
        dir("${BASE_DIR}/01-infra") {
          sh "terraform init -backend-config=${ENV_DIR}/${params.ENVIRONMENT}-infra-backend.hcl"
          sh "terraform validate"
        }
      }
    }

    stage('Layer 1: Plan') {
      steps {
        dir("${BASE_DIR}/01-infra") {
          script {
            if (params.ACTION == 'destroy') {
              sh "terraform plan -destroy -var-file=${ENV_DIR}/${params.ENVIRONMENT}.tfvars -out=infra.tfplan"
            } else {
              sh "terraform plan -var-file=${ENV_DIR}/${params.ENVIRONMENT}.tfvars -out=infra.tfplan"
            }
          }
        }
      }
    }

    // ==========================================
    // LAYER 2: SERVICES (ArgoCD & K8s Bootstrap)
    // ==========================================
    stage('Layer 2: Init & Validate') {
      // Skip Layer 2 init/plan on fresh environment creation (apply) until Layer 1 is deployed
      when {
        expression { params.ACTION == 'destroy' }
      }
      steps {
        dir("${BASE_DIR}/02-services") {
          sh "terraform init -backend-config=${ENV_DIR}/${params.ENVIRONMENT}-services-backend.hcl"
          sh "terraform validate"
          sh "terraform plan -destroy -var-file=${ENV_DIR}/${params.ENVIRONMENT}.tfvars -out=services.tfplan"
        }
      }
    }

    stage('Manual Approval') {
      steps {
        script {
          if (params.ACTION == 'destroy') {
            input message: "⚠️ DANGER: Confirm DESTROYing environment '${params.ENVIRONMENT}' (Services then Infra)?", ok: 'DESTROY ALL'
          } else {
            input message: "Approve Layer 1 Apply for environment '${params.ENVIRONMENT}'?", ok: 'Apply Infra'
          }
        }
      }
    }

    // ==========================================
    // EXECUTION
    // ==========================================
    stage('Execute Actions') {
      steps {
        script {
          if (params.ACTION == 'apply') {
            // Step 1: Apply Layer 1 (Infrastructure)
            dir("${BASE_DIR}/01-infra") {
              echo "Applying Layer 1: Infrastructure..."
              sh "terraform apply infra.tfplan"
            }

            // Step 2: Init, Plan, and Apply Layer 2 (Services) after EKS exists
            dir("${BASE_DIR}/02-services") {
              echo "Initializing and Applying Layer 2: Services..."
              sh "terraform init -backend-config=${ENV_DIR}/${params.ENVIRONMENT}-services-backend.hcl"
              sh "terraform validate"
              sh "terraform plan -var-file=${ENV_DIR}/${params.ENVIRONMENT}.tfvars -out=services.tfplan"
              
              input message: "Approve Layer 2 Apply (ArgoCD Bootstrapping) for environment '${params.ENVIRONMENT}'?", ok: 'Apply Services'
              sh "terraform apply services.tfplan"
            }
          } else {
            // Step 1: Destroy Layer 2 first (Services / LoadBalancers / ArgoCD)
            dir("${BASE_DIR}/02-services") {
              echo "Destroying Layer 2: Services..."
              sh "terraform apply services.tfplan"
            }

            // Step 2: Destroy Layer 1 second (EKS / VPC)
            dir("${BASE_DIR}/01-infra") {
              echo "Destroying Layer 1: Infrastructure..."
              sh "terraform apply infra.tfplan"
            }
          }
        }
      }
    }
  }

  post {
    always {
      // Clean up plan files across both layers
      sh "rm -f ${BASE_DIR}/01-infra/infra.tfplan"
      sh "rm -f ${BASE_DIR}/02-services/services.tfplan"
      cleanWs()
    }
  }
}