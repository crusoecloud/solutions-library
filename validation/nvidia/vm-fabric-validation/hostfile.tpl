%{ for ip in ips ~}
${ip} slots=${gpus}
%{ endfor ~}
