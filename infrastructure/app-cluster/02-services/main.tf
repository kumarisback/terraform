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

# 2. Bootstrap Root Application (App-of-Apps) AFTER ArgoCD and CRDs exist
resource "helm_release" "argocd_root_app" {
  depends_on = [helm_release.argocd]

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