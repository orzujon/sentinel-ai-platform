variable "kubeconfig_path" {
  description = "Dedicated Sentinel kubeconfig; never store credentials in Git."
  type        = string
  default     = "~/.kube/sentinel.yaml"
}

variable "kube_context" {
  description = "Optional explicit kubeconfig context; null uses its current context."
  type        = string
  default     = null
}
