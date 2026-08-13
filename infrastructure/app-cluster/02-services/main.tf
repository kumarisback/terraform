# 1. Install core ArgoCD (Services & CRDs)
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "7.7.15"
  namespace        = "argocd"
  create_namespace = true

  set = concat(
    [
      {
        name  = "server.service.type"
        value = var.enable_argocd_loadbalancer ? "LoadBalancer" : "ClusterIP"
      }
    ],
    var.enable_argocd_loadbalancer ? [
      for idx, cidr in var.argocd_allowed_cidrs : {
        name  = "server.service.loadBalancerSourceRanges[${idx}]"
        value = cidr
      }
    ] : []
  )

  values = [
    yamlencode({
      crds = {
        install = true
      }
    })
  ]
}

# 2. External Secrets Operator, installed before the GitOps root app so the
#    ClusterSecretStore/ExternalSecret CRDs it defines exist before ArgoCD
#    tries to apply CRs of those kinds under platform/ and apps/<env>/.
resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = "0.10.4"
  namespace        = "kube-system"
  create_namespace = false

  values = [
    yamlencode({
      installCRDs = true
      serviceAccount = {
        create = true
        name   = "external-secrets-sa"
        annotations = {
          "eks.amazonaws.com/role-arn" = data.terraform_remote_state.infra.outputs.irsa_role_arns["external_secrets"]
        }
      }
    })
  ]
}

# 3. AWS Load Balancer Controller — real install, replacing the no-op
#    placeholder ConfigMap that used to sit under gitops/platform/. Needed for
#    any Ingress (ALB) or NLB-mode Service; harmless to run even while only
#    plain type:LoadBalancer Services (classic/NLB via the in-tree provider)
#    are in use.
resource "helm_release" "aws_lb_controller" {
  name             = "aws-load-balancer-controller"
  repository       = "https://aws.github.io/eks-charts"
  chart            = "aws-load-balancer-controller"
  version          = "1.8.1"
  namespace        = "kube-system"
  create_namespace = false

  values = [
    yamlencode({
      clusterName = data.terraform_remote_state.infra.outputs.cluster_name
      region      = var.aws_region
      vpcId       = data.terraform_remote_state.infra.outputs.vpc_id
      serviceAccount = {
        create = true
        name   = "aws-load-balancer-controller"
        annotations = {
          "eks.amazonaws.com/role-arn" = data.terraform_remote_state.infra.outputs.irsa_role_arns["aws_lb_controller"]
        }
      }
    })
  ]
}

# 4. Bootstrap Root Application (App-of-Apps) AFTER ArgoCD, CRDs, and ESO exist
resource "helm_release" "argocd_root_app" {
  depends_on = [helm_release.argocd, helm_release.external_secrets]

  name       = "argocd-root-app"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.2"
  namespace  = "argocd"

  values = [
    yamlencode({
      applications = {
        root-app = {
          namespace  = "argocd"
          project    = "default"
          finalizers = ["resources-finalizer.argocd.argoproj.io"]
          source = {
            repoURL        = tostring(var.argocd_gitops_repo_url)
            targetRevision = tostring(var.argocd_gitops_repo_revision)
            path           = tostring(var.argocd_gitops_repo_path)
          }
          destination = {
            server    = "https://kubernetes.default.svc"
            namespace = "argocd"
          }
          syncPolicy = {
            automated = {
              prune    = true
              selfHeal = true
            }
          }
        }
      }
    })
  ]
}