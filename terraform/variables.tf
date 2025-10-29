variable "kubeconfig" {
  description = "Path to the kubeconfig file with cluster credentials."
  type        = string
  default     = "~/.kube/config"
}

variable "kube_context" {
  description = "Optional kubeconfig context name to use."
  type        = string
  default     = null
}

variable "argocd_namespace" {
  description = "Namespace where Argo CD will be installed."
  type        = string
  default     = "argocd"
}

variable "argocd_chart_version" {
  description = "Version of the Argo CD Helm chart."
  type        = string
  default     = "6.7.12"
}

variable "external_secrets_chart_version" {
  description = "Version of the External Secrets Operator Helm chart."
  type        = string
  default     = "0.20.4"
}

variable "external_secrets_store_name" {
  description = "Name of the ClusterSecretStore resource for Vault."
  type        = string
  default     = "vault-cino"
}

variable "external_secrets_vault_server" {
  description = "Vault server URL reachable from the cluster."
  type        = string
}

variable "external_secrets_vault_ca_bundle" {
  description = "Optional PEM-encoded CA bundle for the Vault server."
  type        = string
  default     = null
}

variable "external_secrets_vault_path" {
  description = "Vault KV mount path that stores secrets."
  type        = string
  default     = "secret"
}

variable "external_secrets_vault_kubernetes_mount" {
  description = "Vault auth path for the Kubernetes auth method."
  type        = string
  default     = "kubernetes"
}

variable "external_secrets_vault_role" {
  description = "Vault role bound to the External Secrets service account."
  type        = string
  default     = "cino-backend"
}

variable "external_secrets_service_account_name" {
  description = "Service account name used by External Secrets Operator to auth with Vault."
  type        = string
  default     = "cino-bar-external-secrets"
}

variable "external_secrets_service_account_namespace" {
  description = "Namespace of the External Secrets service account."
  type        = string
  default     = "cino-bar"
}

variable "git_repo_url" {
  description = "Git repository URL that Argo CD should track."
  type        = string
}

variable "git_target_revision" {
  description = "Branch, tag, or commit for Argo CD Applications."
  type        = string
  default     = "main"
}

variable "infrastructure_namespace" {
  description = "Target namespace for infrastructure workloads managed by Argo CD."
  type        = string
  default     = "infrastructure"
}

variable "applications_namespace" {
  description = "Target namespace for application workloads managed by Argo CD."
  type        = string
  default     = "cino-bar"
}
