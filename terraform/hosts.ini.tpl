[bastion]
k3s-bastion ansible_host=${bastion_public_ip} internal_ip=${bastion_internal_ip}

[k3s_masters]
%{ for server in k3s_masters ~}
${server.name} ansible_host=${server.network_interface[0].ip_address} internal_ip=${server.network_interface[0].ip_address} ansible_ssh_common_args="-o StrictHostKeyChecking=no -o ProxyCommand='ssh -W %h:%p -q ubuntu@${bastion_public_ip}'"
%{ endfor ~}

[k3s_workers]
%{ for server in k3s_workers ~}
${server.name} ansible_host=${server.network_interface[0].ip_address} internal_ip=${server.network_interface[0].ip_address} ansible_ssh_common_args="-o StrictHostKeyChecking=no -o ProxyCommand='ssh -W %h:%p -q ubuntu@${bastion_public_ip}'"
%{ endfor ~}

[all:vars]
ansible_user=ubuntu
ansible_ssh_private_key_file=~/.ssh/id_rsa

# Переносим IP балансировщика API, чтобы его видели абсолютно все хосты кластера
yandex_lb_ip=${yandex_lb_ip}







