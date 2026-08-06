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
  default     = "b1g3t25pff7pdao6upbs"
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

variable "admin_allowed_ips" {
  type        = list(string)
  description = "Список административных IP-адресов в формате CIDR (например, ['85.90.10.20/32']), которым разрешен доступ к SSH и Kubernetes API"
}

variable "k3s_workers" {
  type = map(object({
    cores         = number
    memory        = number
    core_fraction = number
    disk_size     = number
    zone          = string
  }))
  description = "Конфигурация воркер-нод кластера k3s (имя ноды -> параметры)"
  default = {
    "worker-1" = {
      cores         = 2
      memory        = 2
      core_fraction = 20
      disk_size     = 15
      zone          = "ru-central1-a"
    },
    "worker-2" = {
      cores         = 2
      memory        = 2
      core_fraction = 20
      disk_size     = 15
      zone          = "ru-central1-a"
    }
  }
}

