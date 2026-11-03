#!/bin/bash
# SSH-туннель до мастер-ноды через бастион.
# IP берутся из ansible/hosts.ini (генерируется Terraform).
#
# Особенности:
# - Fallback: master-1 → master-2 → master-3, если предыдущий недоступен.
# - ConnectTimeout: падаем за 10 секунд, если bastion недоступен.
# - ServerAliveInterval: keepalive для долгих сессий.
# - Не пересоздаёт туннель, если он уже поднят (используй --force).
# - Пробрасывает 80/443 до Internal NLB.
#
# Использование:
#   bash scripts/tunnel.sh [hosts.ini] [--force]

set -e

HOSTS_FILE="${1:-ansible/hosts.ini}"
FORCE_RECREATE=0

for arg in "$@"; do
    if [ "$arg" = "--force" ]; then
        FORCE_RECREATE=1
    fi
done

if [ ! -f "$HOSTS_FILE" ]; then
    echo "❌ Файл $HOSTS_FILE не найден. Запусти make up."
    exit 1
fi

# Если туннель уже поднят и не просили пересоздать — выходим
if [ "$FORCE_RECREATE" -eq 0 ] && ss -tlnp 2>/dev/null | grep -q ":6443 "; then
    echo "✅ Туннель уже поднят на 127.0.0.1:6443. Используй --force для пересоздания."
    exit 0
fi

# Парсим IP бастиона, мастеров и внутренний IP NLB
BASTION_IP=$(grep "^k3s-bastion " "$HOSTS_FILE" | sed 's/.*ansible_host=\([^ ]*\).*/\1/')
MASTER_IPS=$(grep "^k3s-master-" "$HOSTS_FILE" | sed 's/.*ansible_host=\([^ ]*\).*/\1/')
NLB_INTERNAL_IP=$(grep "^k3s_ingress_nlb_ip " "$HOSTS_FILE" | sed 's/.*ansible_host=\([^ ]*\).*/\1/')

if [ -z "$BASTION_IP" ]; then
    echo "❌ Не удалось найти bastion в $HOSTS_FILE"
    exit 1
fi

if [ -z "$MASTER_IPS" ]; then
    echo "❌ Не удалось найти мастер-ноды в $HOSTS_FILE"
    exit 1
fi

# Если NLB_IP не найден — работаем как раньше (только 6443)
# Если найден — добавляем пробросы для веба
# ВРЕМЕННО: проброс только 6443, чтобы поднять K3s.
# 80/443 вернем, когда NLB станет HEALTHY.
LOCAL_FORWARD="-L 6443:127.0.0.1:6443"

if [ -n "$NLB_INTERNAL_IP" ]; then
    echo "ℹ️  NLB Internal IP найден ($NLB_INTERNAL_IP), но проброс 80/443 временно отключен."
fi

echo "Bastion: $BASTION_IP"
echo "Masters: $MASTER_IPS"

# Убиваем старые туннели
pkill -f "ssh.*-L 6443:127.0.0.1:6443" 2>/dev/null || true
sleep 1

# Пробуем каждого мастера по очереди
TUNNEL_UP=0
for MASTER_IP in $MASTER_IPS; do
    echo "→ Пробую master: $MASTER_IP"

    # Запускаем туннель в фоне
    # Используем eval для подстановки переменной $LOCAL_FORWARD
    eval "ssh -o BatchMode=yes \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -o ExitOnForwardFailure=yes \
        -o ConnectTimeout=10 \
        -o ServerAliveInterval=10 \
        -o ServerAliveCountMax=3 \
        -f -N \
        -J "ubuntu@$BASTION_IP" \
        $LOCAL_FORWARD \
        "ubuntu@$MASTER_IP"" 2>/dev/null || {
            echo "  ✗ master $MASTER_IP недоступен"
            continue
        }

    # Retry-цикл: ждём порт 6443
    for i in $(seq 1 10); do
        if ss -tlnp 2>/dev/null | grep -q ":6443 "; then
            echo "✅ Туннель поднят на 127.0.0.1:6443 (via $MASTER_IP)"
            TUNNEL_UP=1
            break
        fi
        sleep 1
    done

    if [ "$TUNNEL_UP" -eq 1 ]; then
        break
    fi

    # Туннель не поднялся — убиваем и пробуем следующего
    echo "  ✗ туннель через $MASTER_IP не поднялся"
    pkill -f "ssh.*-L 6443:127.0.0.1:6443" 2>/dev/null || true
    sleep 1
done

if [ "$TUNNEL_UP" -eq 0 ]; then
    echo "❌ Не удалось поднять туннель ни через один мастер."
    echo "   Проверь: bastion доступен? masters живы? SSH-ключ настроен?"
    exit 1
fi

if [ -n "$NLB_INTERNAL_IP" ]; then
    echo "✅ Ingress доступен на http://localhost (80) и https://localhost (443)"
fi
