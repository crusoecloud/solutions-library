# IPSec tunnel for Crusoe Managed Kubernetes
This provides an IPSec VPN connection between some remote site and a Crusoe Managed Kubernetes (CMK) cluster.

This is primarily a helm chart that contains the following software:
1. A pair of Deployments that are a pair of strongswan instances, designed to run on distinct nodes.
2. BGP daemons that work within those Strongswan deployments to share Kubernetes CIDRs to the remote peer, as well as reflect the remote CIDRs into the cluster.  
3. A Daemonset for each node to run a BGP client to receive the routes from the BGP reflectors above and configure local routes to send traffic to the Strongswan nodes.


Features:
* This is designed to work with Crusoe Managed Kubernetes (CMK) clusters. CMK clusters run Cilium with a vxlan overlay.
* Individual Pod IPs, Node IPs, and Service IPs are all reachable from remote IPs
* All pods can reach remote IPs
* Remote routes are dynamically shared via BGP and updated around the cluster
* The pair of tunnels provide high-availability with fast-failover via BGP withdrawal.

Limitations:
* The specific nodes that run Strongswan must be hard-coded because the remote connection will need static IPs.
* Host networks on CMK nodes cannot initiate connections to remote IPs. Only pods can initiate traffic to remote IPs. Remote IPs can initiate connections to both nodes and pods.
* Traffic both _to_ and _from_ the remote peer may be mislabeled as "world" traffic and thus improperly treated by CiliumNetworkPolicies


## How to deploy

### 1. Upgrade your cilium chart with a few key changes
See `cilium-new-values.yaml` for a few configuration settings that must be set in cilium

```helm upgrade --version 1.16.1 --reuse-values -n kube-system cilium cilium/cilium -f cilium-new-values.yaml```

You may need to restart existing cilium pods for the config changes to be observed:

```kubectl delete pod -n kube-system -lk8s-app=cilium```

### 2. Enable firewall for IPSec traffic
You must select two nodes within your CMK cluster that will run the IPSec tunnels. These nodes must be able to receive inbound traffic on ports `udp/500` and `udp/4500` from the remote public IPs of your IPSec tunnels.

### 3. Deploy ipsec-tunnel-chart
First set the necessary values.  See `values.yaml` of the `ipsec-tunnel-chart`. You will, at a minimum, need to define the following values:
* `localCidrs` must include the node, pod, and service CIDRs of your CMK cluster
* All entries of the `tunnels` values must be defined
* `bgp.peerASN` must be set to the peer BGP ASN

Then deploy into a namespace.  The ipsec-tunnel can be deployed into any Kubernetes namespace.

```helm install -n $NAMESPACE ipsec-tunnel-cmk ./ipsec-tunnel-chart -f values.yaml```


### Troubleshooting

**If you are having problems connecting the IPSec**:
* view the `strongswan` container logs of the `ipsec-tunnel-*` pods for clues
* `kubectl exec -it <ipsec-tunnel-pod> -c strongswan -- ip netns exec strongswan swanctl --list-conns` should show the expected configuration
* `kubectl exec -it <ipsec-tunnel-pod> -c strongswan -- ip netns exec strongswan swanctl --list-sas` should have output if the connection is successful

**If you are seeing problems getting a remote BGP session running**:
* view the `frr` container logs of the `ipsec-tunnel-*` pods for clues
* `kubectl exec -it <ipsec-tunnel-pod> -c frr -- vtysh -c "show bgp summary"` Should see the remote routes as well as your local K8s CIDR ranges

**If you are having other connectivity issues reaching pods on the CMK cluster:**
* view the `frr` container logs of the `ipsec-routes-*` pods for clues. You should see the polled remote routes logged regularly
* `kubectl exec -it <ipsec-routes-pod> -c frr -- vtysh -c "show bgp summary"` Should see the remote routes
* `kubectl exec -it <ipsec-routes-pod> -c frr -- ip route`
  * On a strongswan node, you should see remote routes with no `encap` going straight to `dev ss0`
  * On a non-strongswan node, you should see the remote route present as `encap` with a `dst` to both strongswan nodes, e.g.

    ```
    10.0.0.0/24
        nexthop  encap ip id 2 src 0.0.0.0 dst 172.27.0.1 ttl 0 tos 0 via 169.254.100.5 dev cilium_vxlan weight 1 onlink
        nexthop  encap ip id 2 src 0.0.0.0 dst 172.27.0.2 ttl 0 tos 0 via 169.254.100.5 dev cilium_vxlan weight 1 onlink
    ```

    where 172.27.0.1 and 172.27.0.2 are the internal IPs of strongswan nodes.
     * If no route exists, check the `frr` of a strongswan daemonset pod vs the `frr` of a non-strongswan daemonset pod.

## Terraform example
Included in this repo is a terraform root module. This terraform is an example config that will bring up a Google Cloud VPN in an existing GCP VPC and connect it to a CMK cluster via the `ipsec-tunnel` helm chart. It should work as-is, but is not required for deployment. It is only meant to serve as a reference.