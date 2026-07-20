# ==============================================================================
# 7. ВЫВОД ПЕРЕМЕННЫХ (OUTPUTS)
# ==============================================================================

output "k3s_balancer_public_ip" {
  description = "Публичный IP-адрес облачного балансировщика Yandex NLB"
  value       = one(one(yandex_lb_network_load_balancer.k3s_lb.listener).external_address_spec).address
}

output "k3s_masters_internal_ips" {
  description = "Внутренние IP-адреса мастеров в приватной подсети для Ansible"
  value       = yandex_compute_instance.k3s_masters[*].network_interface[0].ip_address
}





