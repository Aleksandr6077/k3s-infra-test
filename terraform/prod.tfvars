k3s_workers = {
  "worker-1" = {
    cores         = 2
    memory        = 4
    core_fraction = 20
    disk_size     = 30
    zone          = "ru-central1-a"
  }

  "worker-2" = {
    cores         = 2
    memory        = 4
    core_fraction = 20
    disk_size     = 30
    zone          = "ru-central1-d"
  }
}
