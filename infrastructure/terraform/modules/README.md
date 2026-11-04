# Terraform modules

- namespace/: a Terraform-owned Kubernetes namespace with prevent_destroy.
- Planned later: RBAC, monitoring, Istio and application modules.

Modules never configure backends, provider authentication or cross-root state.
