[k3s_masters]
%{ for index, pub_ip in k3s_masters_public_ips ~}
k3s-master-${index + 1} ansible_host=${pub_ip} internal_ip=${k3s_masters_internal_ips[index]}
%{ endfor ~}

[all:vars]
ansible_user=ubuntu
ansible_ssh_private_key_file=~/.ssh/id_rsa
ansible_ssh_common_args='-o StrictHostKeyChecking=no'

# Переносим IP балансировщика сюда, чтобы его видели абсолютно все хосты кластера
yandex_lb_ip=${yandex_lb_ip}


