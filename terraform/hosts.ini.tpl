[k3s_masters]
k3s-master-1 ansible_host=${k3s_masters_public_ips[0]} internal_ip=${k3s_masters_internal_ips[0]}

k3s-master-2 ansible_host=${k3s_masters_internal_ips[1]} internal_ip=${k3s_masters_internal_ips[1]} ansible_ssh_common_args="-o StrictHostKeyChecking=no -o ProxyCommand='ssh -W %h:%p -q ubuntu@${k3s_masters_public_ips[0]}'"

k3s-master-3 ansible_host=${k3s_masters_internal_ips[2]} internal_ip=${k3s_masters_internal_ips[2]} ansible_ssh_common_args="-o StrictHostKeyChecking=no -o ProxyCommand='ssh -W %h:%p -q ubuntu@${k3s_masters_public_ips[0]}'"

[all:vars]
ansible_user=ubuntu
ansible_ssh_private_key_file=~/.ssh/id_rsa

# Переносим IP балансировщика сюда, чтобы его видели абсолютно все хосты кластера
yandex_lb_ip=${yandex_lb_ip}



