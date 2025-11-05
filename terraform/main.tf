terraform {
  required_version = ">= 1.4.0"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.23"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
  }
}

locals {
  kube_context_arg = var.kube_context != null && var.kube_context != "" ? "--context=${var.kube_context}" : ""
  external_secrets_vault_provider = merge({
    server  = var.external_secrets_vault_server
    path    = var.external_secrets_vault_path
    version = "v2"
    auth = {
      kubernetes = {
        mountPath = var.external_secrets_vault_kubernetes_mount
        role      = var.external_secrets_vault_role
        serviceAccountRef = {
          name      = var.external_secrets_service_account_name
          namespace = var.external_secrets_service_account_namespace
        }
      }
    }
  }, var.external_secrets_vault_ca_bundle == null || var.external_secrets_vault_ca_bundle == "" ? {} : { caBundle = var.external_secrets_vault_ca_bundle })
}

provider "kubernetes" {
  config_path    = var.kubeconfig
  config_context = var.kube_context
}

provider "helm" {
  kubernetes {
    config_path    = var.kubeconfig
    config_context = var.kube_context
  }
}

provider "kubectl" {
  config_path       = var.kubeconfig
  config_context    = var.kube_context
  apply_retry_count = 5
}

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version
  namespace        = var.argocd_namespace
  create_namespace = true

  values = [
    file("${path.module}/values/argocd-values.yaml")
  ]
}

resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = var.external_secrets_chart_version
  namespace        = "external-secrets"
  create_namespace = true
}

resource "null_resource" "wait_for_argocd_crds" {
  depends_on = [helm_release.argocd]

  triggers = {
    argocd_release = helm_release.argocd.metadata[0].revision
  }

  provisioner "local-exec" {
    command = "kubectl --kubeconfig=${var.kubeconfig} ${local.kube_context_arg} wait --for=condition=Established --timeout=120s crd/applications.argoproj.io"
  }
}

resource "null_resource" "wait_for_external_secrets_crds" {
  depends_on = [helm_release.external_secrets]

  triggers = {
    external_secrets_release = helm_release.external_secrets.metadata[0].revision
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = "kubectl --kubeconfig=${var.kubeconfig} ${local.kube_context_arg} wait --for=condition=Established --timeout=120s crd/clustersecretstores.external-secrets.io && kubectl --kubeconfig=${var.kubeconfig} ${local.kube_context_arg} wait --for=condition=Established --timeout=120s crd/secretstores.external-secrets.io && kubectl --kubeconfig=${var.kubeconfig} ${local.kube_context_arg} wait --for=condition=Established --timeout=120s crd/externalsecrets.external-secrets.io"
  }
}

resource "kubectl_manifest" "vault_cluster_secret_store" {
  depends_on = [
    null_resource.wait_for_external_secrets_crds,
    kubernetes_service_account.external_secrets_operator
  ]

  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1"
    kind       = "ClusterSecretStore"
    metadata = {
      name = var.external_secrets_store_name
    }
    spec = {
      provider = {
        vault = local.external_secrets_vault_provider
      }
    }
  })
}

resource "kubernetes_service_account" "external_secrets_operator" {
  depends_on = [
    helm_release.external_secrets
  ]

  metadata {
    name      = var.external_secrets_service_account_name
    namespace = var.external_secrets_service_account_namespace
    labels = {
      app = "external-secrets-bootstrap"
    }
  }
}

resource "kubectl_manifest" "bootstrap_argocd_repo_external_secret" {
  depends_on = [
    kubectl_manifest.vault_cluster_secret_store,
    helm_release.argocd
  ]

  yaml_body = file("${path.root}/../infrastructure/argocd-repo-external-secret.yaml")
}

resource "kubectl_manifest" "bootstrap_mysql_external_secret" {
  depends_on = [
    kubectl_manifest.vault_cluster_secret_store,
    kubernetes_namespace.infrastructure
  ]

  yaml_body = file("${path.root}/../infrastructure/mysql-external-secret.yaml")
}
