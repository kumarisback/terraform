pipeline {
  agent any

  parameters {
    choice(name: 'ENVIRONMENT', choices: ['dev', 'staging', 'prod'], description: 'Target environment')
    choice(name: 'ACTION', choices: ['apply', 'destroy'], description: 'Action to perform: apply or destroy')
  }

  environment {
    BASE_DIR           = 'infrastructure/app-cluster'
    ENV_DIR            = "${WORKSPACE}/environments/app-cluster"
    AWS_DEFAULT_REGION = 'us-east-1'
    AWS_REGION         = 'us-east-1'
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
    stage('Layer 2: Init & Validate (Destroy Only)') {
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
              // TEMPORARY — one-time cleanup. The private route table's
              // 0.0.0.0/0 route was originally created via aws_route_table's
              // own inline `route` block, before commit d120388 migrated it
              // to a standalone aws_route resource. Removing that inline
              // block stops Terraform from managing the route but does NOT
              // delete it — it's left orphaned but still present in AWS. The
              // new aws_route.private_nat resource then tries to CREATE a
              // route for that same destination and AWS rejects it as a
              // duplicate. Deleting the orphan here lets the new standalone
              // resource create it fresh. Remove this block after it runs
              // once successfully — do not leave it in permanently.
              echo "One-time: clearing orphaned 0.0.0.0/0 route before Layer 1 apply..."
              sh """
                RTB_ID=\$(aws ec2 describe-route-tables --filters "Name=tag:Name,Values=microservices-${params.ENVIRONMENT}-private-rt-0" --query 'RouteTables[0].RouteTableId' --output text --region ${AWS_REGION})
                echo "Route table: \$RTB_ID"
                aws ec2 delete-route --route-table-id "\$RTB_ID" --destination-cidr-block 0.0.0.0/0 --region ${AWS_REGION} || true
              """

              echo "Applying Layer 1: Infrastructure..."
              sh "terraform apply -auto-approve infra.tfplan"

              // TEMPORARY — one-time fix for a route left over from before
              // modules/networking stopped mixing inline + standalone
              // aws_route on the private route table (see commit d120388).
              // -replace can't be passed to a saved plan file, hence the
              // separate live apply here. Remove this block after it runs
              // once successfully — do not leave it in permanently.
              echo "One-time: forcing recreation of aws_route.to_shared_services[0]..."
              sh "terraform apply -auto-approve -replace='aws_route.to_shared_services[0]' -var-file=${ENV_DIR}/${params.ENVIRONMENT}.tfvars"
            }

            // Step 2: Init & Apply Layer 2 (Services)
            dir("${BASE_DIR}/02-services") {
              echo "Initializing Layer 2: Services..."
              sh "terraform init -backend-config=${ENV_DIR}/${params.ENVIRONMENT}-services-backend.hcl"
              sh "terraform validate"
              
              input message: "Approve Layer 2 Apply (ArgoCD Bootstrapping) for environment '${params.ENVIRONMENT}'?", ok: 'Apply Services'

              echo "Refreshing EKS credentials and applying Layer 2..."
              sh """
                aws eks update-kubeconfig --name microservices-${params.ENVIRONMENT}-eks-cluster --region ${AWS_REGION}
                export KUBECONFIG=~/.kube/config

                # TEMPORARY — one-time cleanup of a Helm release orphaned by an
                # earlier apply that died mid-install during the connectivity
                # issue (cluster-unreachable timeouts, now fixed). Terraform's
                # state has no record of it, so a fresh `helm install` collides
                # with this leftover release object. Remove this block after
                # it runs once successfully — do not leave it in permanently.
                kubectl delete secret -n kube-system -l "owner=helm,name=aws-load-balancer-controller" --ignore-not-found=true || true

                terraform apply -auto-approve -var-file=${ENV_DIR}/${params.ENVIRONMENT}.tfvars
              """
            }
          } else {
            // Step 1: Destroy Layer 2 first (Services)
            dir("${BASE_DIR}/02-services") {
              echo "Destroying Layer 2: Services..."
              sh """
                # Tolerate the cluster already being gone — a normal state to
                # recover from if a previous destroy got partway through
                # Layer 1 (which destroys the EKS cluster before networking)
                # and then failed later on IGW/subnet cleanup. In that case
                # there's nothing live for this layer's Terraform state to
                # reach anyway; let `terraform destroy` run against whatever
                # (if anything) is still in its own state instead of hard-
                # failing here.
                aws eks update-kubeconfig --name microservices-${params.ENVIRONMENT}-eks-cluster --region ${AWS_REGION} \
                  || echo "Cluster not found — assuming it was already destroyed in a prior run; continuing."
                export KUBECONFIG=~/.kube/config
                terraform destroy -auto-approve -var-file=${ENV_DIR}/${params.ENVIRONMENT}.tfvars
              """
            }

            // Step 1.5: Wait for AWS to actually finish tearing down anything
            // GitOps-managed that gets an ephemeral public IP on an ENI (the
            // ALB from gitops/apps/base/ingress.yaml, previously also the
            // frontend LoadBalancer's ELB). Terraform destroy on Layer 2 only
            // waits for the Kubernetes objects to delete, not for the AWS-side
            // cleanup those deletions trigger — that's asynchronous and can
            // lag a couple of minutes, which is long enough for Layer 1's IGW/
            // subnet deletion to hit "has some mapped public address(es),
            // please unmap before detaching" if it starts immediately after.
            dir("${BASE_DIR}/01-infra") {
              script {
                // '|| true' so a hard failure here (e.g. state already fully
                // destroyed) doesn't throw. Terraform prints its "state file
                // has no outputs defined" message to STDOUT (not stderr), so
                // redirecting stderr away isn't enough to keep it out of this
                // variable — instead of trusting it's empty, validate it
                // actually looks like a VPC ID before ever using it below.
                def vpcId = sh(script: "terraform output -raw vpc_id 2>&1 || true", returnStdout: true).trim()
                if (!(vpcId ==~ /^vpc-[0-9a-fA-F]+$/)) {
                  echo "No valid VPC ID in Layer 1 state (got: '${vpcId}') — assuming it's already destroyed; skipping ENI wait."
                } else {
                  echo "Waiting for all public-IP-mapped ENIs in ${vpcId} to clear before destroying networking..."
                  sh """
                    for i in \$(seq 1 30); do
                      COUNT=\$(aws ec2 describe-network-interfaces \
                        --filters Name=vpc-id,Values=${vpcId} \
                        --query "length(NetworkInterfaces[?Association.PublicIp!=null])" \
                        --output text)
                      echo "Attempt \$i: \$COUNT ENI(s) in ${vpcId} still have a mapped public IP"
                      if [ "\$COUNT" = "0" ]; then
                        echo "All clear — no mapped public IPs remain."
                        break
                      fi
                      sleep 10
                    done
                  """
                }
              }
            }

            // Step 2: Destroy Layer 1 second (Infra)
            dir("${BASE_DIR}/01-infra") {
              echo "Destroying Layer 1: Infrastructure..."
              sh "terraform destroy -auto-approve -var-file=${ENV_DIR}/${params.ENVIRONMENT}.tfvars"
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