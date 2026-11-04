variable "name" {
  type        = string
  description = "Exact namespace name."
}

variable "labels" {
  type        = map(string)
  description = "Approved ownership and Pod Security labels."
}
