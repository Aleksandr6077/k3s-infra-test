.PHONY: up down recreate

# 1. Поднятие стенда одной командой
up:
	@echo "====> Развертывание чистой инфраструктуры k3s... <===="
	cd ansible && ansible-playbook -i hosts.ini setup-env.yaml -k

# 2. Полное удаление стенда одной командой
down:
	@echo "====> Уничтожение кластера k3s и очистка хоста... <===="
	sudo k3s-uninstall.sh

# 3. Пересборка (сначала снос, потом автоматическое поднятие)
recreate: down up
