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
}

# Приватная подсеть для остальных мастеров — трафик в интернет идет через NAT-шлюз
resource "yandex_vpc_subnet" "k3s_private_subnet" {
  name           = "k3s-private-subnet"
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.k3s_network.id
  v4_cidr_blocks = ["10.200.2.0/24"]
  route_table_id = yandex_vpc_route_table.k3s_route_table.id # Привязываем NAT-шлюз только сюда
}

# Новая изолированная приватная подсеть строго для воркеров
resource "yandex_vpc_subnet" "k3s_workers_subnet" {
  name           = "k3s-workers-subnet"
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.k3s_network.id
  v4_cidr_blocks = ["10.200.3.0/24"]
  route_table_id = yandex_vpc_route_table.k3s_route_table.id # Переиспользуем NAT-шлюз
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

# ГРУППА 2: Периметр для нод кластера
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
  count       = 1
  name        = "k3s-master-${count.index + 1}"
  zone        = "ru-central1-a"
  platform_id = "standard-v3"

  # Метки для инвентаря Ansible
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
    # ПЕРЕСАЖИВАЕМ ВОРКЕРЫ В ИЗОЛИРОВАННУЮ ПОДСЕТЬ (10.200.3.0/24)
    subnet_id          = yandex_vpc_subnet.k3s_workers_subnet.id
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
# 5.2 Передаем IP-адрес балансировщика в файл(чтобы не было ошибки "Unhandled Error" err="couldn't get current server API group list)# ==============================================================================
#resource "local_file" "lb_ip" {
  #content  = "yandex_lb_ip: ${[
    #for addr in one(yandex_lb_network_load_balancer.k3s_lb.listener).external_address_spec :
    #addr.address
  #][0]}"
  #filename = "${path.module}/../ansible/group_vars/all/lb_ip.yml"
#}

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
      
      # Заменили заглушку [] на реальный ресурс воркер-нод
      k3s_workers = yandex_compute_instance.k3s_workers
    }
  )
  filename = "${path.module}/../ansible/hosts.ini"
}

















