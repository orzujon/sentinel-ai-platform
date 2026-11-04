# Kubernetes, kube-system and Flannel remain owned by Ansible.
module "platform_namespace" {
  source = "../../../modules/namespace"

  name = "sentinel-platform"
  labels = {
    "app.kubernetes.io/part-of"        = "sentinel"
    "app.kubernetes.io/managed-by"     = "terraform"
    "pod-security.kubernetes.io/audit" = "restricted"
    "pod-security.kubernetes.io/warn"  = "restricted"
  }
}
