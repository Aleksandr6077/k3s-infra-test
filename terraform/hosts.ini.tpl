[k3s_masters]
%{ for index, ip in k3s_masters_ips ~}
k3s-master-${index + 1} ansible_host=${ip}
%{ endfor ~}

[loadbalancers]
haproxy-1 ansible_host=${haproxy_ip}

[all:vars]
ansible_user=ubuntu
ansible_ssh_private_key_file=~/.ssh/id_rsa
ansible_ssh_common_args='-o StrictHostKeyChecking=no'
