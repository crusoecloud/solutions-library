import json
import urllib.parse

import kubernetes.config
import kubernetes.client
import pulumi.log
import requests

def discover_k8s_oidc_info_from_kubeconfig() -> str:
    """
    Fetches the OIDC Issuer URL and JWKS JSON from the cluster's
    API server using the local kubeconfig for authentication.
    """
    try:
        # 1. Load Kubeconfig
        kubernetes.config.load_kube_config()
        
        # 2. Build the OIDC config URL from the Kubeconfig host
        #    This assumes the OIDC discovery doc is hosted by the API server.
        client = kubernetes.client.ApiClient()

        response, status, headers = client.call_api('/openid/v1/jwks', 'GET', async_req=False, response_type='json', _preload_content=False)
        assert status == 200, f"Failed to fetch JWKS from cluster, status: {status}"
        jwks_json = response.data.decode('utf-8')
        jwks_json = json.dumps(json.loads(jwks_json), sort_keys=True, indent=2)
        return jwks_json

    except Exception as e:
        pulumi.log.error(f"Failed to auto-discover OIDC info from cluster: {e}")
        pulumi.log.error("Please ensure your kubeconfig is valid and can access the cluster.")
        pulumi.log.error("Alternatively, you can manually set 'oidcIssuerUrl' and 'oidcIssuerJwks' in your Pulumi config.")
        raise e
