# ==============================================================================
# OBJECT STORAGE ДЛЯ LOKI
# ==============================================================================

# Рандомный суффикс, чтобы бакеты не конфликтовали при пересоздании
resource "random_id" "suffix" {
  byte_length = 4
}

# 1. Сервисный аккаунт для Loki
resource "yandex_iam_service_account" "loki_sa" {
  name = "k3s-loki-sa"
}

# 2. Выдаем права на Object Storage
resource "yandex_resourcemanager_folder_iam_member" "loki_editor" {
  folder_id = var.yc_folder_id
  role      = "storage.editor" # Для записи чанков и чтения
  member    = "serviceAccount:${yandex_iam_service_account.loki_sa.id}"
}

# 3. Статический ключ доступа (access_key + secret_key)
resource "yandex_iam_service_account_static_access_key" "loki_key" {
  service_account_id = yandex_iam_service_account.loki_sa.id
  description        = "Loki S3 access key"
}

# 4. Бакет для логов
resource "yandex_storage_bucket" "loki_chunks" {
  bucket     = "k3s-loki-chunks-${random_id.suffix.hex}"
  folder_id  = var.yc_folder_id
  access_key = yandex_iam_service_account_static_access_key.loki_key.access_key
  secret_key = yandex_iam_service_account_static_access_key.loki_key.secret_key

  # Запрещаем удаление бакета командой terraform destroy
  lifecycle {
    prevent_destroy = true
  }
}

# 5. Экспортируем данные для Ansible
output "loki_s3_bucket" {
  value = yandex_storage_bucket.loki_chunks.bucket
}

output "loki_s3_access_key" {
  value     = yandex_iam_service_account_static_access_key.loki_key.access_key
  sensitive = true
}

output "loki_s3_secret_key" {
  value     = yandex_iam_service_account_static_access_key.loki_key.secret_key
  sensitive = true
}
