# ==============================================================================
# 7. ВЫВОД ПЕРЕМЕННЫХ (OUTPUTS) 
# ==============================================================================

output "k3s_masters_internal_ips" {
  description = "Внутренние IP-адреса мастеров в приватной подсети для Ansible"
  value       = yandex_compute_instance.k3s_masters[*].network_interface[0].ip_address
}

output "bastion_public_ip" {
  description = "Публичный IP-адрес Бастиона для SSH-доступа"
  value       = yandex_compute_instance.bastion.network_interface[0].nat_ip_address
}

output "k3s_workers_internal_ips" {
  description = "Внутренние IP-адреса воркеров в приватной подсети для Ansible"
  value       = [for worker in yandex_compute_instance.k3s_workers : worker.network_interface[0].ip_address]
}






