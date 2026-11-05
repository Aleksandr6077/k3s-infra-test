# ==============================================================================
# OBJECT STORAGE ДЛЯ LOKI
# ==============================================================================

# Рандомный суффикс, чтобы бакеты не конфликтовали при пересоздании
resource "random_id" "suffix" {
  byte_length = 4
}

# 1. Сервисный аккаунт для Loki
resource "yandex_iam_service_account" "loki_sa" {
  name = "k3s-loki-sa-${terraform.workspace}"
}

# 2. Выдаем права на Object Storage
resource "yandex_resourcemanager_folder_iam_member" "loki_editor" {
  folder_id = var.yc_folder_id
  role      = "storage.admin" # Для записи чанков и чтения
  member    = "serviceAccount:${yandex_iam_service_account.loki_sa.id}"
}

# 3. Статический ключ доступа (access_key + secret_key)
resource "yandex_iam_service_account_static_access_key" "loki_key" {
  service_account_id = yandex_iam_service_account.loki_sa.id
  description        = "Loki S3 access key"
}

# 4. Бакет для логов
resource "yandex_storage_bucket" "loki_chunks" {
  bucket     = "k3s-loki-chunks-${random_id.suffix.hex}-${terraform.workspace}"
  folder_id  = var.yc_folder_id
  access_key = yandex_iam_service_account_static_access_key.loki_key.access_key
  secret_key = yandex_iam_service_account_static_access_key.loki_key.secret_key

  # Запрещаем удаление бакета командой terraform destroy
  lifecycle {
    prevent_destroy = true
  }

  # Явная зависимость от выдачи прав
  depends_on = [
    yandex_resourcemanager_folder_iam_member.loki_editor
  ]
}

# ==============================================================================
# LOCKBOX + ESO
# ==============================================================================

# 1. Сервисный аккаунт для External Secrets Operator
resource "yandex_iam_service_account" "eso_sa" {
  name = "k3s-eso-sa-${terraform.workspace}"
}

# 2. Право читать секреты в Lockbox (на всю папку)
resource "yandex_resourcemanager_folder_iam_member" "eso_lockbox_viewer" {
  folder_id = var.yc_folder_id
  role      = "lockbox.payloadViewer"
  member    = "serviceAccount:${yandex_iam_service_account.eso_sa.id}"
}

# 3. Авторизованный ключ для ESO (именно его ESO кладёт в K8s Secret)
resource "yandex_iam_service_account_key" "eso_key" {
  service_account_id = yandex_iam_service_account.eso_sa.id
  description        = "ESO authorized key"
}

# 4. Сам секрет в Lockbox (сюда кладём пароль Grafana, токен Telegram и т.д.)
resource "yandex_lockbox_secret" "monitoring_secrets" {
  name = "monitoring-secrets-${terraform.workspace}"
}

resource "yandex_lockbox_secret_version" "monitoring_v1" {
  secret_id = yandex_lockbox_secret.monitoring_secrets.id
  entries {
    key        = "grafana_admin_user"
    text_value = "admin"
  }
  entries {
    key        = "grafana_admin_password"
    text_value = var.vault_grafana_admin_password  # или захардкодь временно
  }
  entries {
    key        = "telegram_bot_token"
    text_value = var.vault_TELEGRAM_BOT_TOKEN
  }
  entries {
    key        = "telegram_chat_id"
    text_value = var.vault_TELEGRAM_CHAT_ID
  }
}

# 5. Секрет Lockbox для Loki S3 (ключи, которые генерит Terraform)
resource "yandex_lockbox_secret" "loki_s3" {
  name = "loki-s3-secrets-${terraform.workspace}"
}

resource "yandex_lockbox_secret_version" "loki_s3_v1" {
  secret_id = yandex_lockbox_secret.loki_s3.id
  entries {
    key        = "AWS_ACCESS_KEY_ID"
    text_value = yandex_iam_service_account_static_access_key.loki_key.access_key
  }
  entries {
    key        = "AWS_SECRET_ACCESS_KEY"
    text_value = yandex_iam_service_account_static_access_key.loki_key.secret_key
  }
  entries {
    key        = "LOKI_BUCKET"
    text_value = yandex_storage_bucket.loki_chunks.bucket
  }
}

# Outputs для Ansible (ID секретов и ключ ESO)
output "eso_authorized_key" {
  value     = yandex_iam_service_account_key.eso_key.private_key
  sensitive = true
}

output "lockbox_monitoring_secret_id" {
  value = yandex_lockbox_secret.monitoring_secrets.id
}

output "lockbox_loki_secret_id" {
  value = yandex_lockbox_secret.loki_s3.id
}
