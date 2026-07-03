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
