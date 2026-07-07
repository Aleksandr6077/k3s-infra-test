output "k3s_balancer_public_ip" {
  description = "Публичный IP-адрес облачного балансировщика Yandex NLB"
  value       = yandex_vpc_address.lb_ip.external_ipv4_address[0].address
}

output "k3s_masters_public_ips" {
  description = "Публичные IP-адреса мастеров для управления через Ansible"
  value       = yandex_compute_instance.k3s_masters[*].network_interface[0].nat_ip_address
}


