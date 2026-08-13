output "argocd_namespace" {
  value = helm_release.argocd.namespace
}

data "kubernetes_service_v1" "argocd_server" {
  depends_on = [helm_release.argocd]

  metadata {
    name      = "argocd-server"
    namespace = "argocd"
  }
}

output "argocd_server_url" {
  description = "The external URL/address for the ArgoCD server"
  value = var.enable_argocd_loadbalancer ? (
    length(data.kubernetes_service_v1.argocd_server.status[0].load_balancer[0].ingress) > 0 ? (
      try(
        "http://${data.kubernetes_service_v1.argocd_server.status[0].load_balancer[0].ingress[0].hostname}",
        "http://${data.kubernetes_service_v1.argocd_server.status[0].load_balancer[0].ingress[0].ip}"
      )
    ) : "Pending LoadBalancer Provisioning..."
  ) : "ClusterIP (Use kubectl port-forward)"
}