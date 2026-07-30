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
# 2. ФАЙРВОЛ (SECURITY GROUP)
# ==============================================================================
resource "yandex_vpc_security_group" "k3s_sg" {
  name        = "k3s-security-group"
  description = "Правила фильтрации трафика для k3s (Production-ready)"
  network_id  = yandex_vpc_network.k3s_network.id

  # Входящий SSH на Бастион из внешнего мира (только для админа)
  ingress {
    protocol       = "TCP"
    description    = "Разрешить SSH на Bastion извне (только для админа)"
    v4_cidr_blocks = var.admin_allowed_ips
    port           = 22
  }

  # Входящий SSH на Мастера изнутри сети (только с Бастиона)
  ingress {
    protocol       = "TCP"
    description    = "Разрешить SSH на приватные ноды только из внутренней публичной подсети (где Bastion)"
    v4_cidr_blocks = ["10.200.1.0/24"] # CIDR вашей k3s_public_subnet
    port           = 22
  }

  # Входящий HTTP (открыт для всех пользователей)
  ingress {
    protocol       = "TCP"
    description    = "Входящий HTTP для веб-сервисов"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 80
  }

  # Входящий HTTPS (открыт для всех пользователей)
  ingress {
    protocol       = "TCP"
    description    = "Входящий HTTPS для веб-сервисов"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 443
  }

  # Входящий трафик для Kubernetes API (Защищенный Control Plane)
  ingress {
    protocol       = "TCP"
    description    = "Kubernetes API (Только админ + Healthchecks балансировщика Yandex)"
    v4_cidr_blocks = local.k3s_api_allowed_cidrs
    port           = 6443
  }

  # Разрешаем ВСЁ внутри всего диапазона проекта для межсерверного общения K3s (etcd/Flannel/Calico)
  ingress {
    protocol       = "ANY"
    description    = "Внутренний трафик между публичной и приватной подсетями"
    v4_cidr_blocks = ["10.200.1.0/24", "10.200.2.0/24"]
    from_port      = 0
    to_port        = 65535
  }

  # Исходящий трафик в интернет (скачивание образов, пакетов, обновлений)
  egress {
    protocol       = "ANY"
    description    = "Разрешить выход в интернет"
    v4_cidr_blocks = ["0.0.0.0/0"]
    from_port      = 0
    to_port        = 65535
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
    security_group_ids = [yandex_vpc_security_group.k3s_sg.id]
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
    security_group_ids = [yandex_vpc_security_group.k3s_sg.id] # Ограничим доступ на следующем шаге
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
# 6. ГЕНЕРАЦИЯ ИНВЕНТАРЯ ANSIBLE (HOSTS.INI) — ОБНОВЛЕННАЯ
# ==============================================================================
resource "local_file" "ansible_inventory" {
  content = templatefile("${path.module}/hosts.ini.tpl",
    {
      # Передаем IP-адреса нового выделенного Бастиона
      bastion_public_ip   = yandex_compute_instance.bastion.network_interface[0].nat_ip_address
      bastion_internal_ip = yandex_compute_instance.bastion.network_interface[0].ip_address

      # Собираем только внутренние IP мастеров (публичных у них больше нет)
      k3s_masters_internal_ips = [for vm in yandex_compute_instance.k3s_masters : vm.network_interface[0].ip_address]
      
      # Безопасно вытаскиваем чистую строку IP-адреса из listener балансировщика API
      yandex_lb_ip = tolist(tolist(yandex_lb_network_load_balancer.k3s_lb.listener)[0].external_address_spec)[0].address
    }
  )
  filename = "${path.module}/../ansible/hosts.ini"
}














