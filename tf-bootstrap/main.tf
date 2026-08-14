terraform {
  required_version = ">= 1.6.0" # Минимальная версия OpenTofu/Terraform
  required_providers {
    yandex = {
      source  = "yandex-cloud/yandex"
      version = ">= 0.100.0"
    }
  }
}

# Настройка провайдера Yandex Cloud
provider "yandex" {
  # Токен передаем через переменную окружения TF_VAR_yc_token в терминале
  folder_id = var.yc_folder_id 
}

# Описание переменной
variable "yc_folder_id" {
  type        = string
  description = "b1g3t25pff7pdao6upbs"
}

# Создаем саму базу данных YDB (Serverless)
resource "yandex_ydb_database_serverless" "tf_state_lock" {
  name      = "terraform-state-lock-db"
  folder_id = var.yc_folder_id

  # ХАРДКОРНАЯ ЗАЩИТА: OpenTofu физически откажется удалять эту базу, 
  # даже если запустишь тут destroy
  deletion_protection = true 
}

# Выводим Эндпоинт базы данных в аутпут
output "ydb_document_api_endpoint" {
  value       = yandex_ydb_database_serverless.tf_state_lock.document_api_endpoint
  description = "Скопируйте этот URL для параметра dynamodb_endpoint в backend s3"
}
