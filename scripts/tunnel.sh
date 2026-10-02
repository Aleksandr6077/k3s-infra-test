#!/bin/bash
# SSH-туннель до первого мастера через бастион.
# IP берутся из ansible/hosts.ini (генерируется Terraform).

set -e

HOSTS_FILE="${1:-ansible/hosts.ini}"

if [ ! -f "$HOSTS_FILE" ]; then
    echo "❌ Файл $HOSTS_FILE не найден. Запусти make up."
    exit 1
fi

# Парсим IP бастиона и мастера
BASTION_IP=$(grep "^k3s-bastion " "$HOSTS_FILE" | sed 's/.*ansible_host=\([^ ]*\).*/\1/')
MASTER_IP=$(grep "^k3s-master-1 " "$HOSTS_FILE" | sed 's/.*ansible_host=\([^ ]*\).*/\1/')

if [ -z "$BASTION_IP" ] || [ -z "$MASTER_IP" ]; then
    echo "❌ Не удалось найти bastion или master-1 в $HOSTS_FILE"
    exit 1
fi

echo "Bastion: $BASTION_IP"
echo "Master:  $MASTER_IP"

# Убиваем старые туннели
pkill -f "ssh.*6443" 2>/dev/null || true
sleep 1

# Запускаем туннель в фоне
ssh -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    -o ExitOnForwardFailure=yes \
    -f -N \
    -J "ubuntu@$BASTION_IP" \
    -L 6443:127.0.0.1:6443 \
    "ubuntu@$MASTER_IP"

sleep 2

# Проверяем
if sudo ss -tlnp 2>/dev/null | grep -q 6443; then
    echo "✅ Tunnel is up on 127.0.0.1:6443"
else
    echo "❌ Tunnel failed"
    exit 1
fi
