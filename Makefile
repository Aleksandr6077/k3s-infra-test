.PHONY: up down recreate

# 1. Поднятие стенда одной командой
up:
	@echo "====> Развертывание чистой инфраструктуры k3s... <===="
	cd ansible && ansible-playbook -i hosts.ini setup-env.yaml -K

# 2. Полное удаление стенда одной командой
down:
	@echo "ВНИМАНИЕ! Это действие полностью уничтожит кластер и сбросит сетевые интерфейсы хоста."
	@if [ -f /usr/local/bin/k3s-uninstall.sh ]; then \
		sudo /usr/local/bin/k3s-uninstall.sh; \
	else \
		echo "Скрипт удаления не найден. Кластер k3s уже очищен или еще не был установлен."; \
	fi

# 3. Пересборка (сначала снос, потом автоматическое поднятие)
recreate: down up

