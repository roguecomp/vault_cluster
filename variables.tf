variable "env" {
  description = "The Vault Cluster Environment"
  type        = string
}

variable "region" {
  description = "AWS Region to deploy Vault Cluster to"
  type        = string
}

variable "prefix" {
  description = "Name of the Project"
  type        = string
}

variable "vault_version_tag" {
  description = "The Tag of the Image to pull"
  type        = string
}

variable "docker_hub_image_name" {
  description = "Image URI to pull from"
  type        = string
  default     = "hashicorp/vault"
}

variable "container_cpu" {
  description = "CPU capability of each container"
  type        = number
}

variable "container_memory" {
  description = "Memory of each container"
  type        = number
}

variable "desired_count" {
  description = "Number of Vault nodes to deploy"
  type        = number
  default     = 1
}
variable "port" {
  description = "Vault port"
  type        = number
  default     = 8200
}

variable "dns" {
  description = "URL to deploy vault to under prefix vault."
  type        = string
  default     = "kappadelta.link"
}
