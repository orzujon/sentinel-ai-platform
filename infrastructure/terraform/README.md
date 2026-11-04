# Sentinel Terraform — Windows-local Kubernetes management

Status: **source-only foundation**. No cluster resources have been applied, and no local Windows state files have been created by this GitHub change.

## Ownership boundary

- Infrastructure/Level 1 and Ansible own VMs, Ubuntu, containerd, kubeadm, Flannel bootstrap and node recovery.
- Terraform owns **only** explicitly approved in-cluster platform objects.
- Terraform CLI runs natively on Windows, not WSL. The already configured kubeconfig lives under ~/.kube/sentinel.yaml and should target https://10.78.0.30:6443.
- No monitoring, Istio, Vault, Sentinel, Helm release or existing cluster component is installed, modified or imported here.

## Independent local state files

| Root under environments/level1 | Windows local backend state | Current resources |
| --- | --- | --- |
| 00-foundation | C:\Sentinel\TerraformState\level1\foundation.tfstate | One new namespace sentinel-platform, **plan only** |
| 10-observability | C:\Sentinel\TerraformState\level1\observability.tfstate | None yet |
| 20-service-mesh | C:\Sentinel\TerraformState\level1\service-mesh.tfstate | None yet |
| 30-applications | C:\Sentinel\TerraformState\level1\applications.tfstate | None yet |

Each root has its own state. Modules are reusable definitions with no backend credentials. The local backend supports filesystem locking but is intended for one trusted Windows workstation, not concurrent remote users.

**Never commit state, saved plans, kubeconfig files, tokens, keys or real tfvars.** State and plan data may contain secrets. An encrypted backup stored on a *different physical device* is needed for disk failure recovery; the local Backups directory alone does not provide that.

## Step 1 — Prepare Windows local state, no cluster mutation

Prerequisites: Terraform 1.17.1 or later, kubectl.exe, native Windows PowerShell, and the previously configured private Sentinel kubeconfig.

~~~powershell
cd C:\Users\Orzu\projects\sentinel-ai-platform
terraform version
.\infrastructure\terraform\scripts\Initialize-SentinelTerraformState.ps1
.\infrastructure\terraform\scripts\Test-SentinelTerraformTarget.ps1
icacls C:\Sentinel\TerraformState\level1
~~~

The initialization script only creates the local **directories** at C:\Sentinel\TerraformState\level1 and C:\Sentinel\Backups\TerraformState and restricts their ACLs. It does not create or overwrite .tfstate files. The target check reads the API address, exact cp01/w01 identities, private IPs and Ready conditions without changing the cluster.

## Step 2 — First read-only Terraform plan

~~~powershell
$root = 'infrastructure/terraform/environments/level1/00-foundation'
terraform -chdir=$root init
terraform -chdir=$root validate
.\infrastructure\terraform\scripts\Test-SentinelTerraformTarget.ps1
terraform -chdir=$root plan -out='C:/Sentinel/TerraformState/level1/foundation.tfplan'
terraform -chdir=$root show 'C:/Sentinel/TerraformState/level1/foundation.tfplan'
~~~

Expected **only if no previous namespace exists:** 1 to add (the isolated namespace named sentinel-platform), 0 to change, 0 to destroy. A Terraform plan may contact Kubernetes to refresh state, but does not mutate the cluster. Do not apply if the plan differs, targets the wrong cluster or offers unintended changes.

**A separate explicit operator approval is required before any apply.** Run the read-only target check again immediately before applying the exact reviewed binary plan. Verify the namespace and rerun a plan afterward to establish zero unexpected drift. No apply is authorized by this repository change.

## Versions, locks and CI

- Terraform CLI 1.17.1; Kubernetes provider exactly 3.4.0; Helm provider exactly 3.3.0 in the three reserved roots.
- The CI workflow runs format checking, init with -backend=false, and validate. There is no plan/apply, cluster access or secret access in GitHub Actions.
- During the first trusted provider init, review and commit the generated .terraform.lock.hcl files for **all four roots** before applying any resources. Do not run init -upgrade in controlled deployments.
- Intentionally no resources in observability, service-mesh or applications. Add them by later reviewed and separately approved PRs.
- Keep Ansible-managed kube-system and Flannel out of Terraform management until an explicit, evidence-backed ownership migration.

References: HashiCorp documentation for local backend, Kubernetes and Helm providers.
