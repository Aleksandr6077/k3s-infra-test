# ==============================================================================
# НАСТРОЙКИ И ПЕРЕМЕННЫЕ
# ==============================================================================
TOFU_DIR    := terraform
ANSIBLE_DIR := ansible

VAULT_FILE  := $(ANSIBLE_DIR)/group_vars/all/vault.yml
PASS_FILE   := .ansible_vault_pass.txt
SA_KEY_FILE := sa_key.json

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
	ansible-playbook -i $(ANSIBLE_DIR)/hosts.ini $(ANSIBLE_DIR)/site.yaml --syntax-check

ansible-test:
	ansible-playbook -i $(ANSIBLE_DIR)/hosts.ini $(ANSIBLE_DIR)/site.yaml --check --diff

ansible-deploy:
	ansible-playbook -i $(ANSIBLE_DIR)/hosts.ini $(ANSIBLE_DIR)/site.yaml

# ==============================================================================
# ОСНОВНЫЕ ТАРГЕТЫ УПРАВЛЕНИЯ СТЕНДОМ (YANDEX CLOUD)
# ==============================================================================

## init: Однократная инициализация и миграция локального стейта в S3
init:
	@if [ ! -f "$(SA_KEY_FILE)" ]; then echo "$(RED)Ошибка: $(SA_KEY_FILE) не найден$(NC)"; exit 1; fi
	@echo "$(CYAN)====> Инициализация проекта и миграция стейта... <====$(NC)"
	cd $(TOFU_DIR) && tofu init
	@echo "$(GREEN)====> Инициализация завершена. Проект связан с S3 бэкендом! <====$(NC)"

## up: Развертывание или обеспечение базовой HA-инфраструктуры
up:
	@echo "$(CYAN)====> Развертывание базовой HA-инфраструктуры в 1 поток... <====$(NC)"
	cd $(TOFU_DIR) && TF_VAR_yc_token=$$(yc iam create-token) tofu apply -parallelism=1 -auto-approve
	@echo "$(GREEN)====> Инфраструктура успешно обновлена! <====$(NC)"
	@echo "$(YELLOW)Для деплоя K3s и сервисов запустите: make ansible-deploy$(NC)"

## upgrade: Инициализация OpenTofu в оффлайн-режиме с валидным токеном Яндекса
upgrade:
	cd $(TOFU_DIR) && TF_VAR_yc_token=$$(yc iam create-token) tofu init -reconfigure
	@echo "$(GREEN)====> Инициализация успешно завершена! <====$(NC)"


list:
	cd $(TOFU_DIR) && TF_VAR_yc_token=$$(yc iam create-token) tofu state list
	@echo "$(GREEN)====> Инициализация успешно завершена! <====$(NC)"

plan:
	cd $(TOFU_DIR) && TF_VAR_yc_token=$$(yc iam create-token) tofu plan
	@echo "$(GREEN)====> План конфигурации успешно построен! <====$(NC)"

## down: Полное уничтожение облачной инфраструктуры (OpenTofu Destroy)
down:
	@echo "$(RED)ВНИМАНИЕ! Это действие полностью уничтожит всю облачную инфраструктуру!$(NC)"
	cd $(TOFU_DIR) && TF_VAR_yc_token=$$(yc iam create-token) tofu destroy -auto-approve
	@echo "$(GREEN)====> Облачный стенд полностью уничтожен. <====$(NC)"

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










