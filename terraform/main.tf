# ==============================================================================
# 0. ЛОКАЛЬНЫЕ ПЕРЕМЕННЫЕ ОКРУЖЕНИЯ
# ==============================================================================

locals {
  # Автоматически определяем текущую среду (dev или prod)
  env = terraform.workspace

# Выбираем список зон для мастеров текущего окружения
  # Для prod: [a, d, e], для dev: [a, d, a]
  current_zones = var.env_zones[local.env]

# Выделяем уникальный набор физических зон для создания подсетей (без дублей)
  # Для prod: [a, d, e], для dev: [a, d] (убирает дубль зоны 'а', чтобы не было ошибки неуникального имени подсети)
  unique_zones = distinct(local.current_zones)

# Служебные диапазоны Yandex Cloud для проверок здоровья (Healthchecks) балансировщика NLB
  yc_internal_lb_healthchecks = [
    "198.18.235.0/24",
    "198.18.248.0/24"
  ]

# Объединяем IP админа, CI/CD и healthcheck-диапазоны Яндекса в один список для порта K3s API
  k3s_api_allowed_cidrs = concat(
    var.admin_allowed_ips,
    var.cicd_allowed_ips,
    local.yc_internal_lb_healthchecks
  )

}

# ==============================================================================
# 1. ДИНАМИЧЕСКАЯ СЕТЕВАЯ ИНФРАСТРУКТУРА (VPC И ПОДСЕТИ)
# ==============================================================================

resource "yandex_vpc_network" "k3s_network" {
  name = "k3s-network-${local.env}"
}

# Создаем публичные подсети динамически (только для тех зон, которые есть в окружении)
resource "yandex_vpc_subnet" "k3s_public_buckets" {
  for_each       = toset(local.unique_zones)
  name           = "k3s-public-subnet-${local.env}-${each.key}"
  zone           = each.key
  network_id     = yandex_vpc_network.k3s_network.id
  # Авто-генерация CIDR: для dev-a: 10.100.1.0/24, dev-d: 10.101.1.0/24 и т.д.
  v4_cidr_blocks = [each.key == "ru-central1-a" ? "10.200.1.0/24" : each.key == "ru-central1-d" ? "10.201.1.0/24" : "10.203.1.0/24"]
}

# Создаем приватные подсети для мастеров
resource "yandex_vpc_subnet" "k3s_private_subnets" {
  for_each       = toset(local.unique_zones)
  name           = "k3s-private-subnet-${local.env}-${each.key}"
  zone           = each.key
  network_id     = yandex_vpc_network.k3s_network.id
  route_table_id = yandex_vpc_route_table.k3s_route_table.id
  v4_cidr_blocks = [each.key == "ru-central1-a" ? "10.200.2.0/24" : "10.202.2.0/24"]
}

# Создаем приватные подсети для воркеров
resource "yandex_vpc_subnet" "k3s_workers_subnets" {
  for_each       = toset(local.unique_zones)
  name           = "k3s-workers-subnet-${local.env}-${each.key}"
  zone           = each.key
  network_id     = yandex_vpc_network.k3s_network.id
  route_table_id = yandex_vpc_route_table.k3s_route_table.id
  v4_cidr_blocks = [each.key == "ru-central1-a" ? "10.200.3.0/24" : "10.202.3.0/24"]
}

# Создаем шлюз NAT
resource "yandex_vpc_gateway" "k3s_nat_gateway" {
  name = "k3s-nat-gateway-${local.env}"
  shared_egress_gateway {}
}

# Создаем таблицу маршрутизации для приватного контура
resource "yandex_vpc_route_table" "k3s_route_table" {
  name       = "k3s-route-table-${local.env}"
  network_id = yandex_vpc_network.k3s_network.id

  static_route {
    destination_prefix = "0.0.0.0/0"
    gateway_id         = yandex_vpc_gateway.k3s_nat_gateway.id
  }
}


# ==============================================================================
# 2. ФАЙРВОЛ (РАЗДЕЛЬНЫЕ SECURITY GROUPS ПО РОЛЯМ)
# ==============================================================================

# ГРУППА 1: Изолированный периметр для Бастиона
resource "yandex_vpc_security_group" "bastion_sg" {
  name        = "k3s-bastion-security-group"
  description = "Правила фильтрации трафика строго для Bastion-хоста"
  network_id  = yandex_vpc_network.k3s_network.id

  # Входящий SSH на Бастион из внешнего мира (Только твой домашний IP)
  ingress {
    protocol       = "TCP"
    description    = "Разрешить SSH на Bastion извне (только для админа)"
    v4_cidr_blocks = var.admin_allowed_ips
    port           = 22
  }

  # Исходящий трафик для Бастиона наружу и внутрь сети
  egress {
    protocol       = "ANY"
    description    = "Разрешить Бастиону любой исходящий трафик"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

# ГРУППА 3: Периметр для внутреннего NLB
resource "yandex_vpc_security_group" "nlb_sg" {
  name        = "k3s-nlb-security-group"
  description = "Правила для внутреннего NLB (доступ к NodePort Traefik)"
  network_id  = yandex_vpc_network.k3s_network.id

  # NLB стучится на воркеры по NodePort. Так как NLB внутренний,
  # он ходит с внутренних IP подсети воркеров.
  egress {
    protocol       = "TCP"
    description    = "Трафик от NLB к NodePort Traefik на воркерах"
    v4_cidr_blocks = ["10.200.3.0/24", "10.202.3.0/24"] # подсети воркеров
    port           = 30360
  }
  egress {
    protocol       = "TCP"
    description    = "Трафик от NLB к NodePort Traefik (HTTPS) на воркерах"
    v4_cidr_blocks = ["10.200.3.0/24", "10.202.3.0/24"]
    port           = 31181
  }
}


# ГРУППА 2: Периметр для нод кластера
resource "yandex_vpc_security_group" "cluster_sg" {
  name        = "k3s-cluster-security-group"
  description = "Правила фильтрации трафика для мастеров и воркеров кластера"
  network_id  = yandex_vpc_network.k3s_network.id

  # Входящий SSH на ноды кластера (РАЗРЕШЕН СТРОГО С БАСТИОНА ПО ЕГО SG ID)
  ingress {
    protocol          = "TCP"
    description       = "Разрешить SSH на ноды только для участников bastion_sg"
    security_group_id = yandex_vpc_security_group.bastion_sg.id
    port              = 22
  }

  # Полное доверие между нодами кластера (Концепция self_security_group)
  ingress {
    protocol          = "ANY"
    description       = "Межнодовое общение (etcd, Flannel VXLAN, Kubelet) внутри кластера"
    predefined_target = "self_security_group"
  }

  # Входящий Kubernetes API для внешнего мира (для домашнего kubectl)
  ingress {
    protocol       = "TCP"
    description    = "Kubernetes API для внешнего управления"
    v4_cidr_blocks = local.k3s_api_allowed_cidrs
    port           = 6443
  }

  # Входящий HTTP/HTTPS для приложений (Ingress на воркерах)
  # РАЗРЕШАЕМ ТРАФИК ТОЛЬКО ИЗ ПОДСЕТЕЙ, ГДЕ ЖИВУТ NLB И ВОРКЕРЫ
  ingress {
    protocol       = "TCP"
    description    = "Traefik HTTP NodePort (из подсетей воркеров/NLB)"
    predefined_target = "loadbalancer_healthchecks"
    port           = 30360
  }
  ingress {
    protocol       = "TCP"
    description    = "Traefik HTTPS NodePort (из подсетей воркеров/NLB)"
    predefined_target = "loadbalancer_healthchecks"
    port           = 31181
  }

  # Исходящий трафик для кластера (необходим для работы NAT-шлюза)
  egress {
    protocol       = "ANY"
    description    = "Разрешить любой исходящий трафик нодам кластера"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

# ==============================================================================
# 3. ОБРАЗ ОПЕРАЦИОННОЙ СИСТЕМЫ
# ==============================================================================
data "yandex_compute_image" "ubuntu" {
  family = "ubuntu-2204-lts"
}

# ==============================================================================
# 4. ВИРТУАЛЬНЫЕ МАШИНЫ (K3S MASTERS) — С ПОДДЕРЖКОЙ ФЕЙК-ЗОН
# ==============================================================================
resource "yandex_compute_instance" "k3s_masters" {
  count       = length(local.current_zones) # Создаст 3 мастера всегда
  name        = "k3s-master-${local.env}-${count.index + 1}"
  zone        = local.current_zones[count.index] # На dev: а, затем d, затем снова а
  platform_id = "standard-v3"

  labels = {
    repo       = "k3s-infra-${local.env}"
    role       = "k3s-master"
    is_bastion = "false"
  }

  resources {
    cores         = 2
    memory        = 4
    core_fraction = 20
  }

  scheduling_policy {
    preemptible = true
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.ubuntu.id
      size     = 10
      type     = "network-ssd"
    }
  }

  network_interface {
    # ищет созданную подсеть по имени зоны текущего мастера.
    # Если мастер идет в зону 'a', он спокойно сядет в существующую подсеть 'а', даже если это второй мастер в этой зоне.
    subnet_id          = yandex_vpc_subnet.k3s_private_subnets[local.current_zones[count.index]].id
    nat                = false
    security_group_ids = [yandex_vpc_security_group.cluster_sg.id]
  }

  metadata = {
    ssh-keys = "ubuntu:${var.ssh_public_key != "" ? var.ssh_public_key : file(var.ssh_public_key_path)}"
  }
}

# ==============================================================================
# 4.0 ВИРТУАЛЬНЫЕ МАШИНЫ (K3S WORKERS) — ИСПРАВЛЕНА ПРИВЯЗКА К ПОДСЕТЯМ
# ==============================================================================
resource "yandex_compute_instance" "k3s_workers" {
  for_each    = var.k3s_workers
  name        = "k3s-${each.key}-${local.env}"
  zone        = each.value.zone
  platform_id = "standard-v3"

  labels = {
    repo       = "k3s-infra-${local.env}"
    role       = "k3s-worker"
    is_bastion = "false"
  }

  resources {
    cores         = each.value.cores
    memory        = each.value.memory
    core_fraction = each.value.core_fraction
  }

  scheduling_policy {
    preemptible = true
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.ubuntu.id
      size     = each.value.disk_size
      type     = "network-ssd"
    }
  }

  network_interface {
    # Динамически берем подсеть воркеров по зоне из map
    subnet_id          = yandex_vpc_subnet.k3s_workers_subnets[each.value.zone].id
    nat                = false
    security_group_ids = [yandex_vpc_security_group.cluster_sg.id]
  }

  metadata = {
    ssh-keys = "ubuntu:${var.ssh_public_key != "" ? var.ssh_public_key : file(var.ssh_public_key_path)}"
  }
}


# ==============================================================================
# 4.1 ВЫДЕЛЕННЫЙ BASTION-ХОСТ ДЛЯ БЕЗОПАСНОГО ДОСТУПА ПО SSH
# ==============================================================================
resource "yandex_compute_instance" "bastion" {
  name        = "k3s-bastion-${local.env}"
  zone        = local.unique_zones[0]
  platform_id = "standard-v3"

  labels = {
    repo       = "k3s-infra-test"
    role       = "bastion"
    is_bastion = "true"
  }

  # Минимальные ресурсы для экономии бюджета
  resources {
    cores         = 2
    memory        = 1 # 1 ГБ RAM вполне достаточно для проксирования трафика
    core_fraction = 20
  }

  scheduling_policy {
    preemptible = true # Делаем её прерываемой для максимальной дешевизны
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.ubuntu.id
      size     = 10 # Минимальный размер диска для ОС
      type     = "network-ssd"
    }
  }

  network_interface {
    # БЕРЕМ ПУБЛИЧНУЮ ПОДСЕТЬ ПО ИМЕНИ ЭТОЙ ЗОНЫ
    subnet_id          = yandex_vpc_subnet.k3s_public_buckets[local.unique_zones[0]].id
    nat                = true
    security_group_ids = [yandex_vpc_security_group.bastion_sg.id]
  }

  metadata = {
    ssh-keys = "ubuntu:${var.ssh_public_key != "" ? var.ssh_public_key : file(var.ssh_public_key_path)}"
  }
}

# ==============================================================================
# 5.2 Передаем IP-адрес балансировщика в файл(чтобы не было ошибки "Unhandled Error" err="couldn't get current server API group list)# ==============================================================================
#resource "local_file" "lb_ip" {
  #content  = "yandex_lb_ip: ${[
    #for addr in one(yandex_lb_network_load_balancer.k3s_lb.listener).external_address_spec :
    #addr.address
  #][0]}"
  #filename = "${path.module}/../ansible/group_vars/all/lb_ip.yml"
#}

# ==============================================================================
# 5.  ВНУТРЕННИЙ NLB ДЛЯ INGRESS (80/443)
# ==============================================================================
resource "yandex_lb_target_group" "k3s_ingress_tg" {
  name = "k3s-ingress-target-group"

  dynamic "target" {
    for_each = yandex_compute_instance.k3s_workers
    content {
      subnet_id = target.value.network_interface[0].subnet_id
      address   = target.value.network_interface[0].ip_address
    }
  }
}

resource "yandex_lb_network_load_balancer" "k3s_ingress_nlb" {
  name = "k3s-ingress-nlb"
  type = "internal"

  listener {
    name        = "http"
    port        = 80
    target_port = 30360
    internal_address_spec {
      subnet_id  = yandex_vpc_subnet.k3s_workers_subnets["ru-central1-a"].id
      ip_version = "ipv4"
    }
  }

  listener {
    name        = "https"
    port        = 443
    target_port = 31181
    internal_address_spec {
      subnet_id  = yandex_vpc_subnet.k3s_workers_subnets["ru-central1-a"].id
      ip_version = "ipv4"
    }
  }

  attached_target_group {
    target_group_id = yandex_lb_target_group.k3s_ingress_tg.id

    healthcheck {
      name = "http-healthcheck"
      http_options {
        port = 30360
        path = "/"
      }
    }
  }
}

resource "local_file" "eso_key_file" {
  content  = yandex_iam_service_account_key.eso_key.private_key
  filename = "${path.module}/../ansible/eso_key.pem"
  file_permission = "0600" # Чтобы ключ нельзя было прочитать всем подряд
}

# ==============================================================================
# 6. ГЕНЕРАЦИЯ ИНВЕНТАРЯ ANSIBLE (HOSTS.INI)
# ==============================================================================
resource "local_file" "ansible_inventory" {
  content = templatefile("${path.module}/hosts.ini.tpl",
    {
      # Передаем IP-адреса выделенного Бастиона
      bastion_public_ip   = yandex_compute_instance.bastion.network_interface[0].nat_ip_address
      bastion_internal_ip = yandex_compute_instance.bastion.network_interface[0].ip_address

      # Передаем список объектов мастеров целиком для Jinja2-цикла
      k3s_masters = yandex_compute_instance.k3s_masters

      # Ресурс воркер-нод
      k3s_workers = yandex_compute_instance.k3s_workers

      eso_authorized_key = yandex_iam_service_account_key.eso_key.private_key
      lockbox_monitoring_secret_id = yandex_lockbox_secret.monitoring_secrets.id
      lockbox_loki_secret_id       = yandex_lockbox_secret.loki_s3.id

      # Передаем nlb
      k3s_ingress_nlb_internal_ip = [
        for l in yandex_lb_network_load_balancer.k3s_ingress_nlb.listener :
        one(l.internal_address_spec).address
        if l.name == "http"
      ][0]
    }
  )
  filename = "${path.module}/../ansible/hosts.ini.${local.env}"
}
