# Challenge Vyking Platform Setup

This repository bootstraps a full demo environment built around the **cino-bar** application. Terraform installs all supporting tooling (Argo CD, External Secrets Operator, ingress controllers, Traefik middleware) into a Kubernetes cluster. Argo CD then deploys the Helm chart found in `applications/cino-bar`, which exposes both the frontend (`cinobar.dev`) and backend (`api.cinobar.dev`) over HTTPS and sources secrets from HashiCorp Vault.

The instructions below assume a brand-new workstation. Follow them top-to-bottom to create the cluster, install Vault if required, provision the platform, and verify everything is serving traffic correctly.

---

## 1. Prerequisites

Install the following tools:

- [Docker](https://docs.docker.com/get-docker/) ≥ 24 (required for k3d and Vault containers)
- [k3d](https://k3d.io/v5.8.3/) ≥ 5.8 (or bring your own Kubernetes cluster)
- [kubectl](https://kubernetes.io/docs/tasks/tools/) ≥ 1.29
- [Helm](https://helm.sh/docs/intro/install/) ≥ 3.12
- [Terraform](https://developer.hashicorp.com/terraform/downloads) ≥ 1.4
- [Vault CLI](https://developer.hashicorp.com/vault/docs/install) ≥ 1.15
- (Optional) [Argo CD CLI](https://argo-cd.readthedocs.io/en/stable/cli_installation/) if you prefer triggering syncs from your shell

> **Tip:** Make sure your shell can reach Docker (`docker ps`), k3d (`k3d version`), and Kubernetes (`kubectl version --client`) before continuing.

---

## 2. Create or connect to a Kubernetes cluster

You can deploy to any Kubernetes cluster, but for local development the quickest path is k3d:

```bash
# Create a cluster named devops-cluster with ports 80/443 exposed on the host
k3d cluster create devops-cluster \
  --agents 2 \
  --port "80:80@loadbalancer" \
  --port "443:443@loadbalancer"

# Confirm kubectl talks to it
kubectl get nodes
```

This command exposes ports 80 and 443 on your workstation and keeps the k3s Traefik ingress controller enabled. If you already have a cluster, point `kubectl` at it and skip the create step.

Set the `KUBECONFIG` environment variable if your kubeconfig lives outside the default path:

```bash
export KUBECONFIG=$HOME/.kube/config
```

---

## 3. Clone the repository and configure Terraform

```bash
mkdir -p ~/workspace && cd ~/workspace
git clone git@github.com:mtejada/vykingchallenge.git
cd vykingchallenge
```

Copy or edit `terraform/terraform.tfvars` so it reflects your environment:

```hcl
external_secrets_vault_server = "http://host.k3d.internal:8200"   # Vault URL reachable by the cluster
external_secrets_service_account_namespace = "external-secrets"   # Namespace where ESO runs
external_secrets_service_account_name      = "cino-bar"            # Service account ESO uses to auth with Vault
kubeconfig = "/absolute/path/to/your/kubeconfig"
git_repo_url = "git@github.com:mtejada/vykingchallenge.git" 
```


---

## 4. Prepare HashiCorp Vault

You have two options:

### 4.1 Use an existing Vault

1. Make sure Vault exposes a Kubernetes auth method for the cluster.
2. Create a KV-v2 secret engine at `secret/` (or adjust `terraform/variables.tf` to match your path).
3. Create the following secrets:
   - `secret/cino/prod/backend` with key `DB_PASSWORD`.
   - `secret/cino/staging/backend` with key `DB_PASSWORD`.
   - `secret/argocd/git` containing `url`, `sshPrivateKey`, and `sshKnownHosts` (used by Argo CD to pull this repo).
4. Ensure the Vault role specified by `external_secrets_vault_role` (defaults to `cino-backend`) is bound to the Kubernetes service account that External Secrets Operator uses (`cino-bar` in namespace `external-secrets`).

### 4.2 Run a local Vault container

If you do not have Vault, start a throwaway dev instance via Docker:

```bash
docker run --cap-add=IPC_LOCK -d --name vault-local -p 8200:8200 hashicorp/vault:1.17
docker logs vault-local | grep -E 'Root Token|Unseal Key'
docker network connect k3d-devops-cluster vault-local  # allow the Vault container to reach k3d's API server
# If you named the cluster differently, substitute the correct k3d network.
```

The log output prints a root token you can use for the remaining steps. All `vault …` commands below run **inside the container**; the `kubectl …` commands still run on your host.

```bash
# On the host: capture the GitHub host key and copy required files into the container (generate repo keys and add them to GitHub if you don't have one.)
ssh-keyscan -t ed25519 github.com > /tmp/github_known_hosts
docker cp /tmp/github_known_hosts vault-local:/tmp/github_known_hosts
docker cp /path/to/argocd_repo_key vault-local:/tmp/argocd_repo_key
```

```bash
# Open a shell in the container (optional but handy for multiple commands)
docker exec -it vault-local sh

# Inside the container shell
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=<root token from docker logs>

# Enable KV v2 at secret/
vault secrets enable -path=secret kv-v2
# (If you see "path is already in use at secret/", the dev container already mounted it—skip this step or run `vault secrets disable secret` first to reset.)

# Seed application secrets (use different values if you want prod/staging separation)
vault kv put secret/cino/prod/backend DB_PASSWORD="<prod database password>"
vault kv put secret/cino/staging/backend DB_PASSWORD="<staging database password>"

# Store the Argo CD deploy key (generate one if you do not have it yet)
# sshKnownHosts should contain the host key from: ssh-keyscan -t ed25519 github.com
vault kv put secret/argocd/git \
  url="git@github.com:mtejada/vykingchallenge.git" \
  sshPrivateKey=@/tmp/argocd_repo_key \
  sshKnownHosts=@/tmp/github_known_hosts

# Allow read-only access to those secrets
vault policy write cino-backend - <<'HCL'
path "secret/data/cino/prod/backend" { capabilities = ["read"] }
path "secret/data/cino/staging/backend" { capabilities = ["read"] }
path "secret/data/argocd/git"      { capabilities = ["read"] }
HCL
```

Create a Kubernetes service account that Vault can use for token review (Vault needs the `system:auth-delegator` role to validate pod tokens):

```bash
kubectl -n kube-system create sa vault-auth-sa                # "AlreadyExists" is safe to ignore
kubectl create clusterrolebinding vault-auth-delegator \
  --clusterrole=system:auth-delegator \
  --serviceaccount=kube-system:vault-auth-sa
```

Once the service account exists, mint a reviewer token and capture the cluster details from your host:

```bash
# On the host (NOT in the container)
token_reviewer_jwt=$(kubectl -n kube-system create token vault-auth-sa --duration=24h)
kube_host=https://k3d-devops-cluster-server-0:6443  # adjust if your k3d cluster name differs
ca_crt=$(kubectl -n kube-system get configmap kube-root-ca.crt -o jsonpath='{.data.ca\.crt}')

printf '%s' "$ca_crt" > /tmp/kube-ca.crt
docker cp /tmp/kube-ca.crt vault-local:/tmp/kube-ca.crt
```

With the values exported, configure Vault from the host via `docker exec` (these commands run inside the container, so the Kubernetes host stays intact):

```bash
docker exec \
  -e VAULT_ADDR=http://127.0.0.1:8200 \
  -e VAULT_TOKEN=<root token from docker logs> \
  vault-local \
  sh -c 'vault auth enable kubernetes || true'  # safe to re-run if already enabled

docker exec \
  -e VAULT_ADDR=http://127.0.0.1:8200 \
  -e VAULT_TOKEN=<root token from docker logs> \
  -e TOKEN_REVIEWER_JWT="$token_reviewer_jwt" \
  -e KUBE_HOST="$kube_host" \
  vault-local \
  sh -c 'vault write auth/kubernetes/config \
    kubernetes_host="$KUBE_HOST" \
    token_reviewer_jwt="$TOKEN_REVIEWER_JWT" \
    kubernetes_ca_cert=@/tmp/kube-ca.crt'
```

Finally, create the role Vault will use when External Secrets Operator authenticates:

```bash
docker exec \
  -e VAULT_ADDR=http://127.0.0.1:8200 \
  -e VAULT_TOKEN=<root token from docker logs> \
  vault-local \
  sh -c 'vault write auth/kubernetes/role/cino-backend \
    bound_service_account_names="cino-bar" \
    bound_service_account_namespaces="external-secrets" \
    policies="cino-backend" \
    ttl="1h"'
```

When you are done seeding Vault, remove any temporary copies of your deploy key and host key from `/tmp` (both on the host and inside the container).

Keep the container running while you work. Stop it with `docker stop vault-local` when finished.

---

## 5. Provision cluster tooling with Terraform

```bash
cd terraform
terraform init
terraform apply
```

Terraform installs:

- Argo CD (`argocd` namespace)
- External Secrets Operator (`external-secrets` namespace)
- Service account `cino-bar` in the `external-secrets` namespace to authenticate ESO against Vault
- A `ClusterSecretStore` pointing to Vault
- Argo CD applications that track `infrastructure/` and `applications/`

Because Vault is already configured, External Secrets should transition to `SecretSynced` and Argo CD will be able to clone the repository without manual intervention. If you need to confirm, run `kubectl get clustersecretstore vault-cino -o yaml` and check that `status.conditions[*].type=Ready` is `True`. Auto-sync is enabled, but you can trigger an immediate comparison without the CLI:

```bash
kubectl -n argocd patch application infrastructure --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
kubectl -n argocd patch application cino-bar-apps-prod --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
kubectl -n argocd patch application cino-bar-apps-staging --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

If you prefer using the CLI, grab the admin password and sync manually:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
kubectl -n argocd port-forward svc/argocd-server 8080:80 &
argocd login localhost:8080 --username admin --password <ARGOCD_ADMIN_PASSWORD> --insecure
argocd app sync infrastructure
argocd app sync cino-bar-apps-prod
argocd app sync cino-bar-apps-staging
```

---

## 6. Update DNS (or /etc/hosts)

Add the following entries so your workstation resolves the application hosts to the k3d load balancer:

```
127.0.0.1 cinobar.dev www.cinobar.dev api.cinobar.dev staging-cinobar.dev www.staging-cinobar.dev api.staging-cinobar.dev
```

If you are exposing your cluster through another address, map these hostnames to that IP instead.

> **TLS note:** The repo ships a self-signed certificate stored in `cinobar-dev-cert`. Browsers will warn unless you trust the certificate or replace it with one signed by a known CA. When testing locally, open both `https://cinobar.dev` and `https://api.cinobar.dev` in your browser and bypass the warning (`Advanced → Continue` or `thisisunsafe`) so the browser caches an exception. To generate a trusted cert (e.g., via Let’s Encrypt), update the Kubernetes secret with the new keypair before visiting the site.

---

## 7. Verify the deployment

Run the checks below after Argo CD finishes syncing.

### 7.1 External Secrets and Vault

```bash
kubectl describe externalsecret mysql-credentials -n infrastructure
kubectl get secret mysql-credentials -n infrastructure -o yaml
kubectl describe externalsecret mysql-credentials-staging -n infrastructure
kubectl get secret mysql-credentials-staging -n infrastructure -o yaml
```

Expect both ExternalSecrets to report `SecretSynced` and the generated secrets to contain a `password` field.

### 7.2 Pods and services

Check production and staging namespaces:

```bash
kubectl get pods -n cino-bar-prod
kubectl get svc -n cino-bar-prod
kubectl get ingress -n cino-bar-prod
kubectl get middleware -n cino-bar-prod

kubectl get pods -n cino-bar-staging
kubectl get svc -n cino-bar-staging
kubectl get ingress -n cino-bar-staging
kubectl get middleware -n cino-bar-staging
```

Each namespace should show two frontend pods, two backend pods, and corresponding ingresses (`cinobar.dev` / `www.cinobar.dev` for prod, `staging-cinobar.dev` / `www.staging-cinobar.dev` for staging, plus `api.*`).

### 7.3 HTTP checks

Use `curl` with `--resolve` to hit the endpoints through Traefik. The `-k` flag skips TLS validation for the self-signed certificate.

```bash
curl -k --resolve cinobar.dev:443:127.0.0.1 https://cinobar.dev/
curl -k --resolve api.cinobar.dev:443:127.0.0.1 https://api.cinobar.dev/beverages
curl -k --resolve api.cinobar.dev:443:127.0.0.1 https://api.cinobar.dev/api/v1/beverages

curl -k --resolve staging-cinobar.dev:443:127.0.0.1 https://staging-cinobar.dev/
curl -k --resolve api.staging-cinobar.dev:443:127.0.0.1 https://api.staging-cinobar.dev/beverages
curl -k --resolve api.staging-cinobar.dev:443:127.0.0.1 https://api.staging-cinobar.dev/api/v1/beverages
```

The backend rewrite ensures each API hostname returns the same JSON payload. For database connectivity, tail the backend logs:

```bash
kubectl logs deploy/cino-bar-backend -n cino-bar-prod | tail
kubectl logs deploy/cino-bar-backend -n cino-bar-staging | tail
```

---

## 8. Day-2 Operations

- **Rotate database password:**
  ```bash
  vault kv put secret/cino/prod/backend DB_PASSWORD="new-prod-password"
  kubectl get secret mysql-credentials -n infrastructure -o jsonpath='{.data.password}' | base64 -d

  vault kv put secret/cino/staging/backend DB_PASSWORD="new-staging-password"
  kubectl get secret mysql-credentials-staging -n infrastructure -o jsonpath='{.data.password}' | base64 -d
  ```
  External Secrets Operator refreshes the Kubernetes secret automatically (default every hour).

- **Update the Argo CD deploy key:** upload the new keypair to Vault at `secret/argocd/git` and to GitHub as a read-only deploy key.

- **Sync applications:**
  ```bash
  argocd app list
  argocd app sync cino-bar-apps-prod
  argocd app sync cino-bar-apps-staging
  ```

- **Add new beverages:** use the frontend UI or call the API directly:
  ```bash
  curl -k --resolve api.cinobar.dev:443:127.0.0.1 \
    -H 'Content-Type: application/json' \
    -d '{"name":"Espresso CINO","price":3.5}' \
    https://api.cinobar.dev/beverages
  ```
- **List / retrieve MySQL backups:** for clusters created with k3d (local-path storage) you can inspect the backup PVC from the host node:
  ```bash
  # locate the PVC directory that holds the backups
  docker exec -it k3d-devops-cluster-server-0 \
    ls -lh /var/lib/rancher/k3s/storage/

  # list all backup files once you know the PVC folder name
  docker exec -it k3d-devops-cluster-server-0 \
    ls -lh /var/lib/rancher/k3s/storage/pvc-b7633a10-e88e-4895-92db-3d3b34b61227_infrastructure_mysql-backups

  # copy a specific dump to your workstation
  docker exec -it k3d-devops-cluster-server-0 \
    cat /var/lib/rancher/k3s/storage/pvc-b7633a10-e88e-4895-92db-3d3b34b61227_infrastructure_mysql-backups/backup-20251030185000.sql \
    > backup-20251030185000.sql
  ```
  For non-k3d environments, mount the `mysql-backups` PVC into a helper pod and use `kubectl cp` instead.

---

## 9. Troubleshooting tips

| Symptom | Checks & Fixes |
| --- | --- |
| Pages never load | Ensure `/etc/hosts` (or DNS) points the domains to the cluster IP; confirm `kubectl get ingress -A` lists `cinobar.dev` with an address. |
| TLS errors | Either trust the self-signed cert or replace `cinobar-dev-cert` with a trusted certificate. |
| 404 from backend | Confirm the Traefik middleware exists (`kubectl get middleware -n cino-bar-prod` or `-n cino-bar-staging`) and that the ingress annotation references `<namespace>-cino-bar-backend-prefix@kubernetescrd`. |
| Vault authentication failures | `kubectl describe externalsecret mysql-credentials -n infrastructure` shows ESO events. Ensure the Vault Kubernetes auth role `cino-backend` references the `cino-bar` service account in the `external-secrets` namespace and that the policy allows `secret/cino/prod/backend` and `secret/cino/staging/backend`. Use `kubectl annotate clustersecretstore vault-cino external-secrets.io/refresh=$(date +%s) --overwrite` to force a reconcile after updating Vault. |
| Argo CD stuck `Progressing` | Check `kubectl describe application cino-bar-apps-prod -n argocd` (or `...-staging`) and Argo CD controller logs. Re-sync or inspect Helm errors. |
| Database errors | Verify the MySQL service in `infrastructure/mysql.yaml` is running (`kubectl get pods -n infrastructure`). |

Collect cluster diagnostics with:

```bash
kubectl get events -A --sort-by='.lastTimestamp'
```

---

## 10. Cleanup

Destroy all Kubernetes resources with Terraform:

```bash
cd terraform
terraform destroy
```

If you created a k3d cluster for this demo, remove it afterwards:

```bash
k3d cluster delete devops-cluster
```

For the dev Vault container started earlier:

```bash
docker stop vault-local && docker rm vault-local
```

---

You now have the cino-bar platform running end-to-end on a fresh machine. Enjoy brewing new beverages!
