resource "kubernetes_namespace" "infrastructure" {
  metadata {
    name = var.infrastructure_namespace
  }
}

resource "kubernetes_namespace" "applications" {
  metadata {
    name = var.applications_namespace
  }
}

resource "kubectl_manifest" "argocd_infrastructure_app" {
  depends_on = [
    null_resource.wait_for_argocd_crds,
    null_resource.wait_for_external_secrets_crds,
    kubectl_manifest.vault_cluster_secret_store,
    kubernetes_namespace.infrastructure
  ]

  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "infrastructure"
      namespace = var.argocd_namespace
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.git_repo_url
        targetRevision = var.git_target_revision
        path           = "infrastructure"
        directory = {
          recurse = true
        }
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = kubernetes_namespace.infrastructure.metadata[0].name
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = [
          "CreateNamespace=true",
          "ApplyOutOfSyncOnly=true"
        ]
      }
    }
  })

  wait = true
}

resource "kubectl_manifest" "argocd_applications_app" {
  depends_on = [
    null_resource.wait_for_argocd_crds,
    null_resource.wait_for_external_secrets_crds,
    kubectl_manifest.vault_cluster_secret_store,
    kubernetes_namespace.applications
  ]

  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "cino-bar-apps"
      namespace = var.argocd_namespace
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.git_repo_url
        targetRevision = var.git_target_revision
        path           = "applications/cino-bar"
        helm = {
          releaseName = "cino-bar"
        }
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = kubernetes_namespace.applications.metadata[0].name
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = [
          "CreateNamespace=true",
          "ApplyOutOfSyncOnly=true"
        ]
      }
    }
  })

  wait = true
}
