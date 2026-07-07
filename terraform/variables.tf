variable "yc_token" {
  type        = string
  description = "IAM токен Яндекса"
  default     = null
}

variable "yc_cloud_id" {
  type        = string
  description = "ID твоего облака"
  default     = null
}

variable "yc_folder_id" {
  type        = string
  description = "ID твоего каталога (folder)"
  default     = null
}

variable "ssh_public_key" {
  type        = string
  default     = ""
  description = "Прямое содержимое публичного SSH-ключа. Если пусто, плагин будет искать путь."
}

variable "ssh_public_key_path" {
  type        = string
  default     = "~/.ssh/id_rsa.pub"
  description = "Путь к файлу публичного SSH-ключа на локальной машине."
}

