# Создаем саму базу данных YDB (Serverless)
resource "yandex_ydb_database_serverless" "tf_state_lock" {
  name      = "terraform-state-lock-db"
  folder_id = var.yc_folder_id
}

# Выводим Эндпоинт базы данных в аутпут
output "ydb_document_api_endpoint" {
  value       = yandex_ydb_database_serverless.tf_state_lock.document_api_endpoint
  description = "Скопируйте этот URL для параметра dynamodb_endpoint в backend s3"
}


