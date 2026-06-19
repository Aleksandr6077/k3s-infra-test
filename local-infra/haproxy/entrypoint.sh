#!/bin/sh

# Копируем дефолтный конфиг туда, где у пользователя haproxy точно есть права на запись
cp /etc/keepalived/keepalived.conf /tmp/keepalived.conf

# Если передан приоритет, подменяем его в копии конфига
if [ ! -z "$KEEPALIVED_PRIORITY" ]; then
    sed -i "s/priority 100/priority $KEEPALIVED_PRIORITY/g" /tmp/keepalived.conf
fi

# Запускаем keepalived с указанием кастомного PID-файла в доступной папке
keepalived -n -l -f /tmp/keepalived.conf -p /run/keepalived/keepalived.pid &

# Запускаем HAProxy на переднем плане
exec haproxy -f /usr/local/etc/haproxy/haproxy.cfg


