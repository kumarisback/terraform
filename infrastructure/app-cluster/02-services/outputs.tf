output "argocd_namespace" {
  value = helm_release.argocd.namespace
}

output "argocd_server_url" {
  description = "The external URL/address for the ArgoCD server"
  value       = var.enable_argocd_loadbalancer ? "https://${data.kubernetes_service.argocd_server.status[0].load_balancer[0].ingress[0].hostname}" : "ClusterIP (Use kubectl port-forward)"
}

# Data source to fetch live status of the Service created by Helm
data "kubernetes_service" "argocd_server" {
  depends_on = [helm_release.argocd]

  metadata {
    name      = "argocd-server"
    namespace = "argocd"
  }
}