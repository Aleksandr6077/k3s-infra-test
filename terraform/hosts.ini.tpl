[bastion]
k3s-bastion ansible_host=${bastion_public_ip} internal_ip=${bastion_internal_ip}

[k3s_masters]
k3s-master-1 ansible_host=${k3s_masters_internal_ips[0]} internal_ip=${k3s_masters_internal_ips[0]} ansible_ssh_common_args="-o StrictHostKeyChecking=no -o ProxyCommand='ssh -W %h:%p -q ubuntu@${bastion_public_ip}'"

k3s-master-2 ansible_host=${k3s_masters_internal_ips[1]} internal_ip=${k3s_masters_internal_ips[1]} ansible_ssh_common_args="-o StrictHostKeyChecking=no -o ProxyCommand='ssh -W %h:%p -q ubuntu@${bastion_public_ip}'"

k3s-master-3 ansible_host=${k3s_masters_internal_ips[2]} internal_ip=${k3s_masters_internal_ips[2]} ansible_ssh_common_args="-o StrictHostKeyChecking=no -o ProxyCommand='ssh -W %h:%p -q ubuntu@${bastion_public_ip}'"

[all:vars]
ansible_user=ubuntu
ansible_ssh_private_key_file=~/.ssh/id_rsa

# Переносим IP балансировщика API, чтобы его видели абсолютно все хосты кластера
yandex_lb_ip=${yandex_lb_ip}






