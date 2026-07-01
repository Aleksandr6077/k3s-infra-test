# ==============================================================================
# НАСТРОЙКИ И ПЕРЕМЕННЫЕ
# ==============================================================================
# Пути к каталогам относительно корня проекта
INFRA_DIR   = local-infra
ANSIBLE_DIR = ansible
VAULT_FILE := group_vars/all/vault.yml
PASS_FILE := .ansible_vault_pass.txt

# Балансировщик для проверки доступности API Kubernetes
K8S_API_URL = https://127.0.0.1:6443/readyz

# Цвета для красивого вывода логов в терминал
CYAN   = \033[0;36m
GREEN  = \033[0;32m
YELLOW = \033[0;33m
RED    = \033[0;31m
NC     = \033[0m # No Color

.PHONY: default up down recreate help vault-encrypt vault-decrypt vault-edit ansible-check ansible-test ansible-deploy

# По умолчанию показываем справку, если просто набрали "make"
default: help

# ==============================================================================
# СЕКРЕТЫ И ВАЛИДАЦИЯ (ANSIBLE VAULT)
# ==============================================================================

## vault-encrypt: Зашифровать файл секретов Ansible Vault
vault-encrypt:
	ansible-vault encrypt $(VAULT_FILE)

## vault-decrypt: Расшифровать файл секретов (не рекомендуется коммитить)
vault-decrypt:
	ansible-vault decrypt $(VAULT_FILE)

## vault-edit: Редактировать секреты "на лету" (авто-шифрование при сохранении)
vault-edit:
	ansible-vault edit $(VAULT_FILE)

## ansible-check: Проверить синтаксис плейбука с учетом секретов
ansible-check:
	ansible-playbook -i ansible/hosts.ini ansible/site.yaml --syntax-check

## ansible-test: Запуск плейбука в режиме тестирования (--check --diff)
ansible-test:
	ansible-playbook -i ansible/hosts.ini ansible/site.yaml --check --diff

## ansible-deploy: Накатить конфигурацию на хосты (Реальный деплой вручную)
ansible-deploy:
	ansible-playbook -i ansible/hosts.ini ansible/site.yaml

# ==============================================================================
# ОСНОВНЫЕ ТАРГЕТЫ УПРАВЛЕНИЯ СТЕНДОМ
# ==============================================================================

## up: Поднятие всего стенда одной кнопкой (Инфраструктура + Ожидание API + Деплой)
up:
	@echo "$(CYAN)====> 1. Развертывание HA-инфраструктуры в Docker Compose... <====$(NC)"
	cd $(INFRA_DIR) && docker compose up -d
	
	@echo "$(YELLOW)====> Ожидание инициализации кластера и готовности API (/readyz)... <====$(NC)"
	@until [ $$(curl -s -o /dev/null -w "%{http_code}" --insecure $(K8S_API_URL)) -eq 200 ] || [ $$(curl -s -o /dev/null -w "%{http_code}" --insecure $(K8S_API_URL)) -eq 401 ]; do \
		printf "."; \
		sleep 2; \
	done
	@echo "\n$(GREEN)====> Kubernetes API доступен и готов к работе! <====$(NC)"
	
	@echo "$(CYAN)====> 2. Запуск оркестрации Ansible (Настройка WSL2, импорт Kubeconfig, деплой сервисов)... <====$(NC)"
	ansible-playbook -i ansible/hosts.ini ansible/site.yaml
	
	@echo "$(GREEN)====> Инфраструктура успешно развернута и настроена! <====$(NC)"
	@echo "$(GREEN)Используйте команду 'k get nodes' или 'k9s' для проверки.$(NC)"

## down: Уничтожение стенда с полной очисткой данных и контекстов K8s
down:
	@echo "$(RED)ВНИМАНИЕ! Это действие полностью уничтожит HA-кластер, очистит все PV/PVC и удалит данные.$(NC)"
	cd $(INFRA_DIR) && docker compose down -v
	
	@echo "$(YELLOW)====> Безопасная очистка локального контекста в ~/.kube/config... <====$(NC)"
	@if [ -f ~/.kube/config ]; then \
		kubectl config delete-context k3s-local 2>/dev/null || true; \
		kubectl config delete-cluster k3s-local-cluster 2>/dev/null || true; \
		kubectl config delete-user k3s-local-user 2>/dev/null || true; \
		echo "$(GREEN)Контексты успешно вырезаны. Остальные ваши конфигурации куба целы.$(NC)"; \
	fi
	
	@echo "$(GREEN)====> Стенд полностью уничтожен, локальная среда очищена. <====$(NC)"

## recreate: Быстрая и полная пересборка стенда с нуля (down + up)
recreate: down up

## help: Показать этот список доступных команд
help:
	@echo "$(CYAN)Доступные команды в Makefile:$(NC)"
	@awk '/^## / {print substr($$0, 4)}' $(MAKEFILE_LIST) | awk -F: '{printf "  \033[1;32m%-16s\033[0m %s\033[0m\n", $$1, $$2}'





