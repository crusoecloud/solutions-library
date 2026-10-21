[gb200]
%{ for n in gpu ~}
${n.name} ansible_host=${n.public_ip} private_ip=${n.private_ip} vm_id=${n.vm_id} nvlink_domain_id=${n.nvl_domain}
%{ endfor ~}

[cpu]
%{ for n in cpu ~}
${n.name} ansible_host=${n.public_ip} private_ip=${n.private_ip} vm_id=${n.vm_id}
%{ endfor ~}

[all:vars]
ansible_user=ubuntu
ansible_ssh_private_key_file=${key_path}
ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
