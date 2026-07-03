output "haproxy_public_ip" {
  value       = yandex_compute_instance.haproxy.network_interface[0].nat_ip_address
  description = "Публичный IP балансировщика HAProxy"
}

output "k3s_masters_public_ips" {
  value       = yandex_compute_instance.k3s_masters[*].network_interface[0].nat_ip_address
  description = "Публичные IP адреса мастеров k3s"
}
