To deploy the chart, ensure that:  
 - You have admin kubectl access to the target CMK cluster.
 - You have Helm installed locally
 - Crusoe FS and SSD storage classes are deployed on your CMK cluster
 - Crusoe LoadBalancer helm chart is deployed on your CMK cluster
     
Edit values.yaml to contain your Crusoe Cloud project ID, and enable http tls for the proxy service if desired (strongly recommended!)  
If you're enabling TLS, edit tls-secret.yaml to include the base64-encoded certificate and key of the hostname that you'll point at the loadbalancer public ip.  

Then run:
```
kubectl create ns jupyter
kubectl -n jupyter apply -f tls-secret.yaml
helm dependency update
helm -n jupyter upgrade --install jupyterhub . -f values.yaml --create-
```
Wait for the pods to come to Ready state and for the proxy-public service to be assigned a public IP address:
<img width="737" height="154" alt="image" src="https://github.com/user-attachments/assets/35e64a7e-4a23-4907-972b-a458648503cd" />

<img width="995" height="97" alt="image" src="https://github.com/user-attachments/assets/20c57c5a-dfb4-4045-b287-9ee1c016427d" />

Create a DNS A record that points the FQDN (or one of the FQDNs) specified in your TLS cert, to the public IP address ('EXTERNAL-IP') of the proxy-public service,
then access https://<FQDN> in your browser. Sign into Jupyterhub using your Crusoe Cloud access_key_id and secret_key, which you can typically find in ~/.crusoe/config of your local machine.
