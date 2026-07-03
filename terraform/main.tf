# 1. Создаем виртуальную сеть (VPC)
resource "yandex_vpc_network" "k3s_network" {
  name = "k3s-network"
}

# 2. Создаем подсеть в зоне ru-central1-a (вместо Docker Bridge)
resource "yandex_vpc_subnet" "k3s_subnet" {
  name           = "k3s-subnet"
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.k3s_network.id
  v4_cidr_blocks = ["10.128.0.0/24"]
}

# 3. Настраиваем Security Group (Файрвол)
resource "yandex_vpc_security_group" "k3s_sg" {
  name        = "k3s-security-group"
  description = "Правила фильтрации трафика для k3s"
  network_id  = yandex_vpc_network.k3s_network.id

  # Входящий SSH (порт 22) для Ansible из WSL2
  ingress {
    protocol       = "TCP"
    description    = "Разрешить SSH для управления"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 22
  }

  # Входящий HTTP для балансировщика HAProxy
  ingress {
    protocol       = "TCP"
    description    = "Входящий HTTP"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 80
  }

  # Входящий HTTPS для балансировщика HAProxy
  ingress {
    protocol       = "TCP"
    description    = "Входящий HTTPS"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 443
  }

  # Входящий трафик для Kubernetes API через балансировщик
  ingress {
    protocol       = "TCP"
    description    = "Kubernetes API"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 6443
  }

  # ВАЖНО: Разрешаем ВСЁ внутри подсети, чтобы мастера k3s общались без преград
  ingress {
    protocol       = "ANY"
    description    = "Внутренний трафик между нодами"
    v4_cidr_blocks = ["10.128.0.0/24"]
    from_port      = 0
    to_port        = 65535
  }

  # Исходящий трафик (Egress) — разрешаем виртуалкам качать докер-образы из интернета
  egress {
    protocol       = "ANY"
    description    = "Разрешить выход в интернет"
    v4_cidr_blocks = ["0.0.0.0/0"]
    from_port      = 0
    to_port        = 65535
  }
}

# 4. Получаем актуальный ID образа Ubuntu 22.04 LTS (как в твоем мануале Яндекса)
data "yandex_compute_image" "ubuntu" {
  family = "ubuntu-2204-lts"
}

# 5. Создаем виртуалку для балансировщика HAProxy
resource "yandex_compute_instance" "haproxy" {
  name        = "k3s-haproxy"
  zone        = "ru-central1-a"
  platform_id = "standard-v3" # Самое дешевое актуальное железо (Intel Ice Lake)

  resources {
    cores         = 2
    memory        = 1 # Для HAProxy 1 ГБ оперативки хватит с головой
    core_fraction = 20 # Экономим грант! Берем 20% гарантированной мощности CPU
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.ubuntu.id
      size     = 10 # 10 ГБ диск
    }
  }

  network_interface {
    subnet_id          = yandex_vpc_subnet.k3s_subnet.id
    nat                = true # Выделяем публичный IP, чтобы ты мог достучаться из WSL2
    security_group_ids = [yandex_vpc_security_group.k3s_sg.id]
  }

    metadata = {
    # path.root/../../ заглянет в домашний каталог, но проще написать абсолютный путь через окружение:
    ssh-keys = "ubuntu:${file("/home/redwing/.ssh/id_rsa.pub")}"
  }

}

# 6. Создаем цикл на 3 виртуалки для мастеров k3s
resource "yandex_compute_instance" "k3s_masters" {
  count       = 3
  name        = "k3s-master-${count.index + 1}" # Имена будут k3s-master-1, 2, 3
  zone        = "ru-central1-a"
  platform_id = "standard-v3"

  resources {
    cores         = 2
    memory        = 2  # Для k3s мастера отдаем по 2 ГБ оперативки
    core_fraction = 20 # Тоже берем 20% core fraction для экономии бонусов
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.ubuntu.id
      size     = 15 # 15 ГБ диск под логи и поды
    }
  }

  network_interface {
    subnet_id          = yandex_vpc_subnet.k3s_subnet.id
    nat                = true # Тоже даем им NAT, чтобы Ansible мог ходить напрямую
    security_group_ids = [yandex_vpc_security_group.k3s_sg.id]
  }

  metadata = {
    ssh-keys = "ubuntu:${file("~/.ssh/id_rsa.pub")}"
  }
}

resource "local_file" "ansible_inventory" {
  content = templatefile("${path.module}/hosts.ini.tpl",
    {
      # Для мастеров мы используем [*], так как это цикл count (список машин)
      k3s_masters_ips = yandex_compute_instance.k3s_masters[*].network_interface[0].nat_ip_address
      # А для одиночного HAProxy явно указываем первый интерфейс [0]
      haproxy_ip      = yandex_compute_instance.haproxy.network_interface[0].nat_ip_address
    }
  )
  filename = "${path.module}/../ansible/hosts.ini"
}


