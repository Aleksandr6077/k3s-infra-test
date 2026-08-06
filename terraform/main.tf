locals {
  # Служебные диапазоны Yandex Cloud для проверок здоровья (Healthchecks) балансировщика NLB
  yc_internal_lb_healthchecks = [
    "198.18.235.0/24",
    "198.18.248.0/24"
  ]

  # Объединяем IP и диапазоны проверок Яндекса в один список для порта K3s API
  k3s_api_allowed_cidrs = concat(var.admin_allowed_ips, local.yc_internal_lb_healthchecks)
}

# ==============================================================================
# 1. СЕТЕВАЯ ИНФРАСТРУКТУРА (VPC, ПУБЛИЧНАЯ И ПРИВАТНАЯ СУБНЕТЫ)
# ==============================================================================
resource "yandex_vpc_network" "k3s_network" {
  name = "k3s-network"
}

# Публичная подсеть для Бастиона (k3s-master-1) — трафик идет напрямую без NAT-шлюза
resource "yandex_vpc_subnet" "k3s_public_subnet" {
  name           = "k3s-public-subnet"
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.k3s_network.id
  v4_cidr_blocks = ["10.200.1.0/24"]
  # route_table_id здесь НЕ ПРИВЯЗЫВАЕМ, чтобы не ломать SSH-доступ к белому IP
}

# Приватная подсеть для остальных мастеров — трафик в интернет идет через NAT-шлюз
resource "yandex_vpc_subnet" "k3s_private_subnet" {
  name           = "k3s-private-subnet"
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.k3s_network.id
  v4_cidr_blocks = ["10.200.2.0/24"]
  route_table_id = yandex_vpc_route_table.k3s_route_table.id # Привязываем NAT-шлюз только сюда
}

# Новая изолированная приватная подсеть строго для воркеров (Production-паттерн)
resource "yandex_vpc_subnet" "k3s_workers_subnet" {
  name           = "k3s-workers-subnet"
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.k3s_network.id
  v4_cidr_blocks = ["10.200.3.0/24"]
  route_table_id = yandex_vpc_route_table.k3s_route_table.id # Переиспользуем NAT-шлюз
}

# Подключаем созданный вручную статический IP-адрес через Data Source
data "yandex_vpc_address" "lb_ip" {
  name = "k3s-lb-static-ip"
}

# Создаем шлюз NAT для безопасного выхода в интернет приватных нод
resource "yandex_vpc_gateway" "k3s_nat_gateway" {
  name = "k3s-nat-gateway"
  shared_egress_gateway {}
}

# Создаем таблицу маршрутизации для приватного контура
resource "yandex_vpc_route_table" "k3s_route_table" {
  name       = "k3s-route-table"
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

# ------------------------------------------------------------------------------

# ГРУППА 2: Периметр для нод кластера (Мастера + будущие Воркеры)
resource "yandex_vpc_security_group" "cluster_sg" {
  name        = "k3s-cluster-security-group"
  description = "Правила фильтрации трафика для мастеров и воркеров кластера"
  network_id  = yandex_vpc_network.k3s_network.id

  # Входящий SSH на ноды кластера (РАЗРЕШЕН СТРОГО С БАСТИОНА ПО ЕГО SG ID)
  ingress {
    protocol          = "TCP"
    description       = "Разрешить SSH на ноды только для участников bastion_sg"
    security_group_id = yandex_vpc_security_group.bastion_sg.id # Ссылка на ID группы бастиона
    port              = 22
  }

  # Полное доверие между нодами кластера (Концепция self_security_group)
  ingress {
    protocol          = "ANY"
    description       = "Межнодовое общение (etcd, Flannel VXLAN, Kubelet) внутри кластера"
    predefined_target = "self_security_group"
  }

  # Входящий Kubernetes API для внешнего мира (для твоего домашнего kubectl)
  ingress {
    protocol       = "TCP"
    description    = "Kubernetes API для внешнего управления"
    v4_cidr_blocks = local.k3s_api_allowed_cidrs
    port           = 6443
  }

  # Входящий HTTP/HTTPS для приложений (заготовка под Ingress на воркерах)
  ingress {
    protocol       = "TCP"
    description    = "Входящий HTTP для веб-сервисов"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 80
  }
  ingress {
    protocol       = "TCP"
    description    = "Входящий HTTPS для веб-сервисов"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 443
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
# 4. ВИРТУАЛЬНЫЕ МАШИНЫ (K3S MASTERS) — ПОЛНОСТЬЮ ПРИВАТНЫЕ
# ==============================================================================
resource "yandex_compute_instance" "k3s_masters" {
  count       = 3
  name        = "k3s-master-${count.index + 1}"
  zone        = "ru-central1-a"
  platform_id = "standard-v3"

  # Метки для динамического инвентаря Ansible
  labels = {
    repo       = "k3s-infra-test"
    role       = "k3s-master"
    is_bastion = "false" # Мастера больше не являются бастионами
  }

  resources {
    cores         = 2
    memory        = 2
    core_fraction = 20
  }
  
  # Политика планирования для создания прерываемых (дешевых) ВМ
  scheduling_policy {
    preemptible = true
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.ubuntu.id
      size     = 15
    }
  }

  network_interface {
    # ВСЕ мастера теперь находятся строго в приватной подсети
    subnet_id          = yandex_vpc_subnet.k3s_private_subnet.id
    nat                = false # Публичный IP полностью отключен для всех мастеров
    security_group_ids = [yandex_vpc_security_group.cluster_sg.id]
  }

  metadata = {
    ssh-keys = "ubuntu:${var.ssh_public_key != "" ? var.ssh_public_key : file(var.ssh_public_key_path)}"
  }
}

# ==============================================================================
# 4.0 ВИРТУАЛЬНЫЕ МАШИНЫ (K3S WORKERS) — ДИНАМИЧЕСКОЕ МАСШТАБИРОВАНИЕ
# ==============================================================================
resource "yandex_compute_instance" "k3s_workers" {
  for_each    = var.k3s_workers
  name        = "k3s-${each.key}"
  zone        = each.value.zone
  platform_id = "standard-v3"

  # Метки для инвентаря Ansible
  labels = {
    repo       = "k3s-infra-test"
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
    }
  }

  network_interface {
    # Подключаем к приватной подсети и вешаем общую группу безопасности кластера
    subnet_id          = yandex_vpc_subnet.k3s_private_subnet.id
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
  name        = "k3s-bastion"
  zone        = "ru-central1-a"
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
    }
  }

  network_interface {
    # Бастион сажаем строго в публичную подсеть и выдаем ему публичный IP
    subnet_id          = yandex_vpc_subnet.k3s_public_subnet.id
    nat                = true
    security_group_ids = [yandex_vpc_security_group.bastion_sg.id]
  }

  metadata = {
    ssh-keys = "ubuntu:${var.ssh_public_key != "" ? var.ssh_public_key : file(var.ssh_public_key_path)}"
  }
}


# ==============================================================================
# 5. ОБЛАЧНЫЙ БАЛАНСИРОВЩИК (YANDEX NETWORK LOAD BALANCER)
# ==============================================================================
resource "yandex_lb_target_group" "k3s_masters_group" {
  name = "k3s-masters-target-group"

  dynamic "target" {
    for_each = yandex_compute_instance.k3s_masters
    content {
      # Динамически подставляем ID той подсети, в которой физически нарезана текущая ВМ
      subnet_id = target.value.network_interface[0].subnet_id
      address   = target.value.network_interface[0].ip_address
    }
  }
}

resource "yandex_lb_network_load_balancer" "k3s_lb" {
  name = "k3s-network-load-balancer"

    listener {
    name        = "k3s-api-listener"
    port        = 6443
    target_port = 6443
    
    # синтаксис: извлекаем объект адреса из списка через функцию one()
    external_address_spec {
      address = one(data.yandex_vpc_address.lb_ip.external_ipv4_address).address
    }
  }

  attached_target_group {
    target_group_id = yandex_lb_target_group.k3s_masters_group.id

    healthcheck {
      name = "k3s-api-check"
      tcp_options {
        port = 6443
      }
    }
  }
}

# ==============================================================================
# 5.1 ВНУТРЕННИЙ БАЛАНСИРОВЩИК И ЦЕЛЕВАЯ ГРУППА ДЛЯ ВОРКЕРОВ
# ==============================================================================
resource "yandex_lb_target_group" "k3s_workers_group" {
  name = "k3s-workers-target-group"

  dynamic "target" {
    for_each = yandex_compute_instance.k3s_workers
    content {
      # Используем твой синтаксис обращения к интерфейсу сети
      subnet_id = target.value.network_interface[0].subnet_id
      address   = target.value.network_interface[0].ip_address
    }
  }
}

resource "yandex_lb_network_load_balancer" "k3s_internal_lb" {
  name = "k3s-internal-network-load-balancer"
  type = "internal" # Делает балансировщик строго приватным внутри VPC

  listener {
    name        = "k3s-internal-web-listener"
    port        = 80
    target_port = 80
    
    # Сажаем балансировщик в приватную подсеть
    internal_address_spec {
      subnet_id = yandex_vpc_subnet.k3s_private_subnet.id
    }
  }

  attached_target_group {
    target_group_id = yandex_lb_target_group.k3s_workers_group.id

    # Используем правильное для Яндекса написание healthcheck
    healthcheck {
      name = "http-check"
      http_options {
        port = 80
        path = "/"
      }
    }
  }
}

# ==============================================================================
# 6. ГЕНЕРАЦИЯ ИНВЕНТАРЯ ANSIBLE (HOSTS.INI) — С ЗАГЛУШКОЙ ДЛЯ ВОРКЕРОВ
# ==============================================================================
resource "local_file" "ansible_inventory" {
  content = templatefile("${path.module}/hosts.ini.tpl",
    {
      # Передаем IP-адреса выделенного Бастиона
      bastion_public_ip   = yandex_compute_instance.bastion.network_interface[0].nat_ip_address
      bastion_internal_ip = yandex_compute_instance.bastion.network_interface[0].ip_address

      # Передаем список объектов мастеров целиком для Jinja2-цикла
      k3s_masters = yandex_compute_instance.k3s_masters
      
      # Временная заглушка: пустой список, чтобы шаблон не ругался на отсутствие переменной
      # Как только будет ресурс воркеров, заменю на yandex_compute_instance.k3s_workers
      k3s_workers = []
      
      # Безопасно вытаскиваем чистую строку IP-адреса из listener балансировщика API
      yandex_lb_ip = tolist(tolist(yandex_lb_network_load_balancer.k3s_lb.listener)[0].external_address_spec)[0].address
    }
  )
  filename = "${path.module}/../ansible/hosts.ini"
}
















