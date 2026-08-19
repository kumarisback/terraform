# IRSA-linked ServiceAccounts for controllers that used to be installed here
# via helm_release (aws-load-balancer-controller, external-secrets). Both
# are now ArgoCD-managed Applications instead (see gitops/bootstrap/projects/
# aws-lb-controller-dev.yaml and external-secrets-operator-dev.yaml) — using
# Terraform's helm_release for platform add-ons repeatedly hit "cannot reuse
# a name that is still in use" whenever an apply was interrupted, because
# Terraform's state and Helm's own release bookkeeping are two separate
# sources of truth that can drift. ArgoCD's reconciliation loop is
# idempotent and self-healing by design, which this class of failure isn't
# a problem for. Terraform still owns the IAM/IRSA wiring (that's genuinely
# infrastructure); the ServiceAccount is the minimal Kubernetes-side object
# needed to link a namespace/name to that IAM role, created here so the
# Helm charts installed via ArgoCD can reference it with
# serviceAccount.create=false instead of creating their own.
resource "kubernetes_service_account_v1" "aws_lb_controller" {
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"
    annotations = {
      "eks.amazonaws.com/role-arn" = data.terraform_remote_state.infra.outputs.irsa_role_arns["aws_lb_controller"]
    }
  }
}

resource "kubernetes_service_account_v1" "external_secrets" {
  metadata {
    name      = "external-secrets-sa"
    namespace = "kube-system"
    annotations = {
      "eks.amazonaws.com/role-arn" = data.terraform_remote_state.infra.outputs.irsa_role_arns["external_secrets"]
    }
  }
}

# 1. Install core ArgoCD (Services & CRDs)
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "7.7.15"
  namespace        = "argocd"
  create_namespace = true
  cleanup_on_fail  = true

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
      # bootstrap/envs/<env>/kustomization.yaml references shared
      # bootstrap/projects/*.yaml files via "../../projects/...", and
      # apps/<env>/kustomization.yaml references "../base" — both climb
      # above their own Application's `path`, which kustomize's default
      # load restrictor blocks. There is no working per-Application
      # override for this (ApplicationSource.Kustomize has no
      # `buildOptions` field — an earlier attempt to set
      # spec.source.kustomize.buildOptions per-Application was silently
      # dropped by the API server as an unrecognized field and never took
      # effect). This is the only real mechanism, and it applies
      # argocd-wide.
      configs = {
        cm = {
          "kustomize.buildOptions" = "--load-restrictor LoadRestrictionsNone"
        }
      }
    })
  ]
}

# 2. Bootstrap Root Application (App-of-Apps) — everything else (ArgoCD
# itself excepted, since it's what makes GitOps possible at all) flows
# through this: aws-load-balancer-controller and external-secrets are
# ArgoCD Applications under gitops/bootstrap/projects/, not Terraform
# resources.
resource "helm_release" "argocd_root_app" {
  depends_on = [helm_release.argocd]

  name            = "argocd-root-app"
  repository      = "https://argoproj.github.io/argo-helm"
  chart           = "argocd-apps"
  version         = "2.0.2"
  namespace       = "argocd"
  cleanup_on_fail = true

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
