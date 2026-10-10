[mi355x]
%{ for n in nodes ~}
${n.name} ansible_host=${n.public_ip} private_ip=${n.private_ip} vm_id=${n.vm_id}
%{ endfor ~}

[mi355x:vars]
ansible_user=ubuntu
ansible_ssh_private_key_file=${key_path}
ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
