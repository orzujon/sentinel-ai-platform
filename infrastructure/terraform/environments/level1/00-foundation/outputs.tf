output "platform_namespace" {
  value       = module.platform_namespace.name
  description = "New namespace created only after an approved apply."
}
