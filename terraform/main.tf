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
# 1. СЕТЕВАЯ ИНФРАСТРУКТУРА (VPC, СУБНЕТ, ПУБЛИЧНЫЙ IP)
# ==============================================================================
resource "yandex_vpc_network" "k3s_network" {
  name = "k3s-network"
}

resource "yandex_vpc_subnet" "k3s_subnet" {
  name           = "k3s-subnet"
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.k3s_network.id
  v4_cidr_blocks = ["10.128.0.0/24"]
}

# Выделяем статический публичный IP для балансировщика, чтобы не гадать с индексами
resource "yandex_vpc_address" "lb_ip" {
  name = "k3s-lb-public-ip"
  external_ipv4_address {
    zone_id = "ru-central1-a"
  }
}

# ==============================================================================
# 2. ФАЙРВОЛ (SECURITY GROUP)
# ==============================================================================
resource "yandex_vpc_security_group" "k3s_sg" {
  name        = "k3s-security-group"
  description = "Правила фильтрации трафика для k3s (Production-ready)"
  network_id  = yandex_vpc_network.k3s_network.id

  # Входящий SSH только для доверенных административных IP
  ingress {
    protocol       = "TCP"
    description    = "Разрешить SSH для управления (только для админа)"
    v4_cidr_blocks = var.admin_allowed_ips
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

  # Разрешаем ВСЁ внутри подсети для межсерверного общения K3s (etcd/Flannel/Calico)
  ingress {
    protocol       = "ANY"
    description    = "Внутренний трафик между нодами"
    v4_cidr_blocks = ["10.128.0.0/24"]
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
# 4. ВИРТУАЛЬНЫЕ МАШИНЫ (K3S MASTERS)
# ==============================================================================
resource "yandex_compute_instance" "k3s_masters" {
  count       = 3
  name        = "k3s-master-${count.index + 1}"
  zone        = "ru-central1-a"
  platform_id = "standard-v3"

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
    subnet_id          = yandex_vpc_subnet.k3s_subnet.id
    nat                = true
    security_group_ids = [yandex_vpc_security_group.k3s_sg.id]
  }

  metadata = {
  # Если переменная ssh_public_key не пустая, берем её. Иначе читаем файл по указанному пути.
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
      subnet_id = yandex_vpc_subnet.k3s_subnet.id
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
    
    external_address_spec {
      # Вместо address_id передаем напрямую сгенерированный строковый IP-адрес
      address = yandex_vpc_address.lb_ip.external_ipv4_address[0].address
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
# 6. ГЕНЕРАЦИЯ ИНВЕНТАРЯ ANSIBLE (HOSTS.INI)
# ==============================================================================
resource "local_file" "ansible_inventory" {
  content = templatefile("${path.module}/hosts.ini.tpl",
    {
      k3s_masters_public_ips   = yandex_compute_instance.k3s_masters[*].network_interface[0].nat_ip_address
      k3s_masters_internal_ips = yandex_compute_instance.k3s_masters[*].network_interface[0].ip_address
      # Читаем чистую строку IP из ресурса адреса
      yandex_lb_ip               = yandex_vpc_address.lb_ip.external_ipv4_address[0].address
    }
  )
  filename = "${path.module}/../ansible/hosts.ini"
}







