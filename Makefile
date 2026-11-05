# ==============================================================================
# НАСТРОЙКИ И ПЕРЕМЕННЫЕ
# ==============================================================================
TOFU_DIR    := terraform
ANSIBLE_DIR := ansible

VAULT_FILE  := group_vars/all/vault.yml
VAULT_YML   := group_vars/all/vault.yml
PASS_FILE   := .ansible_vault_pass.txt
SA_KEY_FILE := sa_key.json

# ==============================================================================
# УПРАВЛЕНИЕ ОКРУЖЕНИЯМИ
# ==============================================================================
ENV ?= prod
VAR_FILE := $(ENV).tfvars


# Функция для извлечения значений из Ansible Vault
define get_vault_var
$(shell ansible-vault view $(VAULT_YML) --vault-password-file $(PASS_FILE) 2>/dev/null | grep -E '^$(1):' | sed 's/^[^:]*: *//; s/"//g')
endef

# Экспортируем секреты в переменные окружения OpenTofu (TF_VAR_...)
export TF_VAR_vault_grafana_admin_password = $(call get_vault_var,vault_grafana_admin_password)
export TF_VAR_vault_TELEGRAM_BOT_TOKEN     = $(call get_vault_var,vault_TELEGRAM_BOT_TOKEN)
export TF_VAR_vault_TELEGRAM_CHAT_ID       = $(call get_vault_var,vault_TELEGRAM_CHAT_ID)


# Автоматический экспорт AWS-ключей для S3-бэкенда OpenTofu во все таргеты
export AWS_ACCESS_KEY_ID     = $(shell jq -r '.access_key.id // empty' $(SA_KEY_FILE) 2>/dev/null)
export AWS_SECRET_ACCESS_KEY = $(shell jq -r '.access_key.secret_key // empty' $(SA_KEY_FILE) 2>/dev/null)

# Цвета для красивого вывода логов в терминал
CYAN   = \033[0;36m
GREEN  = \033[0;32m
YELLOW = \033[0;33m
RED    = \033[0;31m
NC     = \033[0m # No Color

.PHONY: default init up down recreate help vault-encrypt vault-decrypt vault-edit ansible-check ansible-test ansible-deploy

# По умолчанию показываем справку
default: help

# ==============================================================================
# СЕКРЕТЫ И ВАЛИДАЦИЯ (ANSIBLE VAULT)
# ==============================================================================

vault-encrypt:
	ansible-vault encrypt $(VAULT_FILE)

vault-decrypt:
	ansible-vault decrypt $(VAULT_FILE)

vault-edit:
	ansible-vault edit $(VAULT_FILE)

ansible-check:
	ansible-playbook -i $(ANSIBLE_DIR)/hosts.ini.$(ENV) $(ANSIBLE_DIR)/site.yaml --syntax-check

ansible-test:
	ansible-playbook -i $(ANSIBLE_DIR)/hosts.ini.$(ENV) $(ANSIBLE_DIR)/site.yaml --check --diff

ansible-deploy: tunnel
	ansible-playbook -i $(ANSIBLE_DIR)/hosts.ini.$(ENV) $(ANSIBLE_DIR)/site.yaml

tunnel:
	@bash scripts/tunnel.sh $(ANSIBLE_DIR)/hosts.ini.$(ENV)

tunnel-force:
	@bash scripts/tunnel.sh $(ANSIBLE_DIR)/hosts.ini.$(ENV) --force

# =============================================================================
# ОСНОВНЫЕ ТАРГЕТЫ УПРАВЛЕНИЯ СТЕНДОМ (YANDEX CLOUD)
# ==============================================================================

## init: Однократная инициализация и миграция локального стейта в S3
init:
	@if [ ! -f "$(SA_KEY_FILE)" ]; then echo "$(RED)Ошибка: $(SA_KEY_FILE) не найден$(NC)"; exit 1; fi
	@echo "$(CYAN)====> Инициализация проекта и миграция стейта... <====$(NC)"
	cd $(TOFU_DIR) && tofu init
	@echo "$(GREEN)====> Инициализация завершена. Проект связан с S3 бэкендом! <====$(NC)"

## upgrade: Инициализация OpenTofu в оффлайн-режиме с валидным токеном Яндекса
upgrade:
	cd $(TOFU_DIR) && TF_VAR_yc_token=$$(yc iam create-token) tofu init -migrate-state
	@echo "$(GREEN)====> Инициализация успешно завершена! <====$(NC)"

workspace-setup:
	@TF_VAR_yc_token=$$(yc iam create-token) tofu -chdir=$(TOFU_DIR) workspace select $(ENV) 2>/dev/null || \
	TF_VAR_yc_token=$$(yc iam create-token) tofu -chdir=$(TOFU_DIR) workspace new $(ENV)

up: workspace-setup
	@echo "$(CYAN)====> Развертывание инфраструктуры [Окружение: $(ENV)]... <====$(NC)"
	cd $(TOFU_DIR) && TF_VAR_yc_token=$$(yc iam create-token) tofu apply -var-file=$(VAR_FILE) -parallelism=1 -auto-approve
	@echo "$(GREEN)====> Инициализация успешно завершена! Для деплоя make ansible-deploy ENV=dev либо prod  <====$(NC)"

plan: workspace-setup
	cd $(TOFU_DIR) && TF_VAR_yc_token=$$(yc iam create-token) tofu plan -var-file=$(VAR_FILE)

down: workspace-setup
	cd $(TOFU_DIR) && TF_VAR_yc_token=$$(yc iam create-token) tofu destroy -var-file=$(VAR_FILE) -auto-approve


## init-upgrade: Обновление лок-файла провайдеров (добавление новых провайдеров)
init-upgrade:
	@echo "$(CYAN)====> Обновление зависимостей провайдеров... <====$(NC)"
	cd $(TOFU_DIR) && TF_VAR_yc_token=$$(yc iam create-token) tofu init -upgrade
	@echo "$(GREEN)====> Провайдеры обновлены! <====$(NC)"

list:
	cd $(TOFU_DIR) && TF_VAR_yc_token=$$(yc iam create-token) tofu state list
	@echo "$(GREEN)====> Инициализация успешно завершена! <====$(NC)"

plan2:
	cd $(TOFU_DIR) && TF_VAR_yc_token=$$(yc iam create-token) tofu plan -lock=false
	@echo "$(GREEN)====> План конфигурации успешно построен! <====$(NC)"

## down-safe: Удалить всё, кроме S3-бакета Loki и его ключей
down-safe: workspace-setup
	@echo "$(RED)Удаление стенда [$(ENV)] с сохранением бакета Loki...$(NC)"
	cd $(TOFU_DIR) && TF_VAR_yc_token=$$(yc iam create-token) tofu destroy -var-file=$(VAR_FILE) -auto-approve \
		-exclude="yandex_storage_bucket.loki_chunks" \
		-exclude="yandex_iam_service_account.loki_sa" \
		-exclude="yandex_iam_service_account_static_access_key.loki_key" \
		-exclude="yandex_lockbox_secret.loki_s3" \
		-exclude="yandex_lockbox_secret_version.loki_s3_v1"

## recreate: Быстрое и безопасное пересоздание инфраструктуры (down + up)
recreate:
	$(MAKE) down && $(MAKE) up

## help: Показать справку по командам
help:
	@echo "$(CYAN)Доступные команды:$(NC)"
	@awk '/^[a-zA-===]/ {config=0} /^##/ {comment=$$0; config=1} /^[a-zA-Z_-]+:/ {if(config) {print "  $(GREEN)" $$1 "$(NC) " substr(comment, 4)}}' $(MAKEFILE_LIST) | column -t -s ':'

apply:
	@echo "$(RED)Делеаем apply...(lock false)$(NC)"
	cd $(TOFU_DIR) && TF_VAR_yc_token=$$(yc iam create-token) tofu apply -lock=false

deletedb:
	@echo "$(RED)Сносим бд в папке терраформа$(NC)"
	cd $(TOFU_DIR) && TF_VAR_yc_token=$$(yc iam create-token) tofu state rm yandex_ydb_database_serverless.tf_state_lock

taint:
	cd $(TOFU_DIR) && TF_VAR_yc_token=$$(yc iam create-token) tofu taint yandex_compute_instance.bastion


testgitops:
	cd $(TOFU_DIR) && TF_VAR_yc_token=$$(yc iam create-token) tofu output -raw k3s_ingress_nlb_ip

## clean-s3: Очистка S3-бакетов (бэкапы PG, tfstate)
clean-s3:
	@echo "$(YELLOW)Очистка S3-бакетов...$(NC)"
	@read -p "Уверен? [y/N] " ans && [ "$$ans" = "y" ] || exit 1
	yc storage s3api rm --bucket <bucket-name> --recursive || true

## tunnel-kill: Убить SSH-туннель
tunnel-kill:
	-@pkill -f "ssh.*-L 6443" 2>/dev/null || true
	@echo "$(GREEN)Туннель убит$(NC)"

## kubeconfig: Показать путь к kubeconfig
kubeconfig:
	@echo "$$HOME/pet2/.kube/config"


## get-lockbox-ids: Показать ID секретов Lockbox для манифестов GitOps
get-lockbox-ids:
	@echo "$(CYAN)=== ID для Loki (вставь в externalsecret-loki.yaml) ===$(NC)"
	cd $(TOFU_DIR) && TF_VAR_yc_token=$$(yc iam create-token) tofu output -raw lockbox_loki_secret_id
	@echo ""
	@echo "$(CYAN)=== ID для Monitoring (вставь в externalsecret-grafana.yaml) ===$(NC)"
	cd $(TOFU_DIR) && TF_VAR_yc_token=$$(yc iam create-token) tofu output -raw lockbox_monitoring_secret_id
	@echo ""

## unlock: Принудительно снять зависшую блокировку состояния (укажи ID в переменной LOCK_ID)
unlock:
	@if [ -z "$(LOCK_ID)" ]; then echo "$(RED)Ошибка: укажи LOCK_ID=$(NC)"; exit 1; fi
	cd $(TOFU_DIR) && TF_VAR_yc_token=$$(yc iam create-token) tofu force-unlock -force $(LOCK_ID)
