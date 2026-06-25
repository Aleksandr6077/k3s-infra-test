FROM haproxy:2.8-alpine

# Переключаемся на root только для установки пакетов и настройки прав
USER root

# Добавляем утилиту setcap для тонкой настройки прав бинарников
RUN apk add --no-cache keepalived iproute2 iputils libcap

# Даем бинарнику keepalived право управлять сетевыми интерфейсами (CAP_NET_ADMIN)
# и открывать сырые сокеты для VRRP (CAP_NET_RAW) без полноценного root
RUN setcap 'cap_net_admin,cap_net_raw=+ep' /usr/sbin/keepalived

# Создаем директории для PID-файлов и логов keepalived, меняя владельца на haproxy
RUN mkdir -p /run/keepalived /var/run && \
    chown -R haproxy:haproxy /run/keepalived /var/run

# Копируем конфиги и выставляем владельцем пользователя haproxy
COPY --chown=haproxy:haproxy keepalived.conf /etc/keepalived/keepalived.conf
COPY --chown=haproxy:haproxy entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh

# Возвращаем безопасного некорневого пользователя HAProxy для рантайма
USER haproxy

ENTRYPOINT ["/entrypoint.sh"]






