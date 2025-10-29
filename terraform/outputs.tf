output "argocd_namespace" {
  description = "Namespace where Argo CD was installed."
  value       = var.argocd_namespace
}

output "argocd_server_service" {
  description = "Service information for the Argo CD API server."
  value = {
    name      = helm_release.argocd.name
    namespace = var.argocd_namespace
  }
}
