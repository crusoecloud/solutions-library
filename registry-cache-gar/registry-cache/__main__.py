import pulumi
import pulumi_gcp as gcp
import pulumi_kubernetes as k8s
import json

from k8s_helpers import discover_k8s_oidc_info_from_kubeconfig

# --- Configuration ---
# These are values you must provide, e.g., via `pulumi config set`
config = pulumi.Config()

registry_htpasswd_content = config.get("registryHtpasswd")
registry_node_port = config.require_int("registryNodePort")
registry_replicas = config.get_int("registryReplicas", 1)

create_registry = config.get("createGarRegistry", False)
registry_name = config.require('garRegistryName')
create_namespace = config.get("createNamespace", False)

# --- Kubernetes Configuration ---
k8s_namespace = config.get("k8sNamespace", "registry-cache")
k8s_service_account_name = "gar-registry-cache-sa"
k8s_app_label = {"app": "registry-cache"}
oidc_issuer_jwks = discover_k8s_oidc_info_from_kubeconfig()
registry_image = config.require("registryImage")
registry_image_pull_secret = config.get("registryImagePullSecret", None)

# --- GCP Provider Configuration ---
gcp_project = gcp.config.project
gcp_location = config.require("gcpLocation")
project = gcp.organizations.get_project(project_id=gcp_project)
project_number = project.number

# === Get or create the Artifact Registry ===
if create_registry:
    gcp.artifactregistry.Repository(registry_name,
        location=gcp_location,
        repository_id=registry_name,
        format="DOCKER",
        description=f"Pulumi-managed registry for registry-cache",
    )

# === Create the Google Service Account (GSA) ===
# This is the identity our proxy will impersonate.
gsa = gcp.serviceaccount.Account("registry-cache-reader",
    account_id="registry-cache-reader",
    display_name="Artifact Registry Reader GSA",
)

# Grant the GSA read-access to the new registry
registry_iam_binding = gcp.artifactregistry.RepositoryIamMember("gsa-read-registry",
    repository=registry_name,
    location=gcp_location,
    role="roles/artifactregistry.reader",
    member=gsa.email.apply(lambda email: f"serviceAccount:{email}"),
)

# === Create the Workload Identity Pool and Provider ===
pool = gcp.iam.WorkloadIdentityPool("registry-cache-pool",
    workload_identity_pool_id="registry-cache-pool",
    display_name="Registry Cache Pool",
)

provider = gcp.iam.WorkloadIdentityPoolProvider("registry-cache-k8s-provider",
    workload_identity_pool_id=pool.workload_identity_pool_id,
    workload_identity_pool_provider_id="registry-cache-k8s-provider",
    display_name="Registry Cache K8s Provider",
    oidc=gcp.iam.WorkloadIdentityPoolProviderOidcArgs(
        issuer_uri='https://kubernetes.default.svc.cluster.local',
        jwks_json=oidc_issuer_jwks,
    ),
    attribute_mapping={
        "google.subject": "assertion.sub",
    },
)

# This is the full audience string we need for the K8s token
audience = pulumi.Output.all(project_number, pool.workload_identity_pool_id, provider.workload_identity_pool_provider_id).apply(
    lambda args: f"//iam.googleapis.com/projects/{args[0]}/locations/global/workloadIdentityPools/{args[1]}/providers/{args[2]}"
)

# === Create the Kubernetes Service Account (KSA) ===
# Assumes your kubeconfig is already set in the environment
k8s_provider = k8s.Provider("k8s-provider")

if create_namespace:
    k8s_namespace_resource = k8s.core.v1.Namespace(k8s_namespace,
        metadata=k8s.meta.v1.ObjectMetaArgs(
            name=k8s_namespace,
        ), opts=pulumi.ResourceOptions(provider=k8s_provider))
else:
    k8s_namespace_resource = k8s.core.v1.Namespace.get("k8s-namespace", k8s_namespace,
        opts=pulumi.ResourceOptions(provider=k8s_provider))

k8s_service_account = k8s.core.v1.ServiceAccount(k8s_service_account_name,
    metadata=k8s.meta.v1.ObjectMetaArgs(
        name=k8s_service_account_name,
        namespace=k8s_namespace_resource.metadata.name,
    )
, opts=pulumi.ResourceOptions(provider=k8s_provider))

# === Link KSA to GSA (WIF IAM Binding) ===
# This allows the KSA (identified by its principal string) to impersonate the GSA.

ksa_principal = pulumi.Output.all(project_number, pool.workload_identity_pool_id).apply(
    lambda args: f"principal://iam.googleapis.com/projects/{args[0]}/locations/global/workloadIdentityPools/{args[1]}/subject/system:serviceaccount:{k8s_namespace}:{k8s_service_account_name}"
)

wif_iam_binding = gcp.serviceaccount.IAMMember("ksa-impersonate-gsa",
    service_account_id=gsa.name, # The resource is the GSA
    role="roles/iam.workloadIdentityUser", # The permission is "impersonate"
    member=ksa_principal, # The identity is our KSA
)

# === Create K8s ConfigMap for WIF (gcp-wif.json) ===
# This file tells 'gcloud' how to use the K8s token to impersonate the GSA
impersonation_url = gsa.email.apply(lambda email: f"https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/{email}:generateAccessToken")

wif_config_dict = {
    "type": "external_account",
    "audience": audience,
    "subject_token_type": "urn:ietf:params:oauth:token-type:jwt",
    "token_url": "https://sts.googleapis.com/v1/token",
    "credential_source": {
        "file": "/var/run/secrets/google/token",
        "format": {
            "type": "text"
        }
    },
    "service_account_impersonation_url": impersonation_url
}

wif_config_map = k8s.core.v1.ConfigMap("gcp-wif",
    metadata=k8s.meta.v1.ObjectMetaArgs(
        name="gcp-wif",
        namespace=k8s_namespace_resource.metadata.name,
    ),
    data={
        "gcp-wif.json": pulumi.Output.from_input(wif_config_dict).apply(json.dumps),
    }
, opts=pulumi.ResourceOptions(provider=k8s_provider))

# === Create K8s ConfigMap for CNCF Registry (config.yml) ===
# This uses the exact content from our working files.
remote_url = f"https://{gcp_location}-docker.pkg.dev"

registry_config_yml = f"""
version: 0.1
log:
  level: info
storage:
  cache:
    blobdescriptor: inmemory
  filesystem:
    rootdirectory: /var/lib/registry
http:
  addr: :5000
auth:
  htpasswd:
    realm: basic-realm
    path: /auth/htpasswd
proxy:
  remoteurl: {remote_url}
  exec:
    command: /docker-credential-gcr
"""

registry_config_map = k8s.core.v1.ConfigMap("cncf-registry-config",
    metadata=k8s.meta.v1.ObjectMetaArgs(
        name="cncf-registry-config",
        namespace=k8s_namespace_resource.metadata.name,
    ),
    data={
        "config.yml": registry_config_yml,
    }
, opts=pulumi.ResourceOptions(provider=k8s_provider))

# === Create the K8s Deployment for CNCF Registry ===
registry_auth_secret = k8s.core.v1.Secret("registry-secret",
    metadata=k8s.meta.v1.ObjectMetaArgs(
        name="registry-secret",
        namespace=k8s_namespace_resource.metadata.name,
    ),
    string_data={
        "htpasswd": registry_htpasswd_content,
    },
    type="Opaque"
, opts=pulumi.ResourceOptions(provider=k8s_provider)
)

registry_deployment = k8s.apps.v1.Deployment("cncf-gar-proxy",
    metadata=k8s.meta.v1.ObjectMetaArgs(
        name="cncf-gar-proxy",
        namespace=k8s_namespace_resource.metadata.name,
        labels=k8s_app_label,
    ),
    spec=k8s.apps.v1.DeploymentSpecArgs(
        replicas=registry_replicas,
        selector=k8s.meta.v1.LabelSelectorArgs(
            match_labels=k8s_app_label,
        ),
        template=k8s.core.v1.PodTemplateSpecArgs(
            metadata=k8s.meta.v1.ObjectMetaArgs(
                labels=k8s_app_label,
            ),
            spec=k8s.core.v1.PodSpecArgs(
                service_account_name=k8s_service_account.metadata.name,
                volumes=[
                    # The projected token for WIF
                    k8s.core.v1.VolumeArgs(
                        name="google-token",
                        projected=k8s.core.v1.ProjectedVolumeSourceArgs(
                            sources=[
                                k8s.core.v1.VolumeProjectionArgs(
                                    service_account_token=k8s.core.v1.ServiceAccountTokenProjectionArgs(
                                        path="token",
                                        audience=audience,
                                        expiration_seconds=3600,
                                    )
                                )
                            ]
                        )
                    ),
                    # The config for WIF itself
                    k8s.core.v1.VolumeArgs(
                        name="gcp-wif",
                        config_map=k8s.core.v1.ConfigMapVolumeSourceArgs(
                            name=wif_config_map.metadata.name
                        )
                    ),
                    k8s.core.v1.VolumeArgs(
                        name="registry-config",
                        config_map=k8s.core.v1.ConfigMapVolumeSourceArgs(
                            name=registry_config_map.metadata.name,
                        )
                    ),
                    # The htpasswd secret for registry auth
                    k8s.core.v1.VolumeArgs(
                        name="htpasswd",
                        secret=k8s.core.v1.SecretVolumeSourceArgs(
                            secret_name=registry_auth_secret.metadata.name,
                        )
                    ),
                ],
                image_pull_secrets=[
                    k8s.core.v1.LocalObjectReferenceArgs(
                        name=registry_image_pull_secret
                    )
                ] if registry_image_pull_secret else None,
                containers=[
                    k8s.core.v1.ContainerArgs(
                        name="registry",
                        image=registry_image,
                        command=["registry", "serve", "/etc/docker/registry/config.yml"],
                        ports=[
                            k8s.core.v1.ContainerPortArgs(
                                container_port=5000,
                                name="registry",
                            )
                        ],
                        env=[
                            k8s.core.v1.EnvVarArgs(
                                name="GOOGLE_APPLICATION_CREDENTIALS",
                                value="/etc/gcp/gcp-wif.json",
                            ),
                        ],
                        volume_mounts=[
                            k8s.core.v1.VolumeMountArgs(
                                name="google-token",
                                mount_path="/var/run/secrets/google",
                                read_only=True,
                            ),
                            k8s.core.v1.VolumeMountArgs(
                                name="gcp-wif",
                                mount_path="/etc/gcp",
                                read_only=True,
                            ),
                            k8s.core.v1.VolumeMountArgs(
                                name="registry-config",
                                mount_path="/etc/docker/registry",
                                read_only=True,
                            ),
                            k8s.core.v1.VolumeMountArgs(
                                name="htpasswd",
                                mount_path="/auth",
                                read_only=True,
                            ),
                        ],
                    )
                ],
            )
        )
    )
, opts=pulumi.ResourceOptions(provider=k8s_provider, depends_on=[wif_iam_binding]))

registry_service = k8s.core.v1.Service("cncf-registry-service",
    metadata=k8s.meta.v1.ObjectMetaArgs(
        name="cncf-registry-service",
        namespace=k8s_namespace_resource.metadata.name,
        labels=k8s_app_label,
    ),
    spec=k8s.core.v1.ServiceSpecArgs(
        selector=k8s_app_label,
        ports=[
            k8s.core.v1.ServicePortArgs(
                port=5000,
                target_port=5000,
                node_port=registry_node_port,
                protocol="TCP",
                name="registry",
            )
        ],
        type="NodePort",
    )
)

# === Exports ===
pulumi.export("googleServiceAccountEmail", gsa.email)
pulumi.export("workloadIdentityPoolName", pool.name)
pulumi.export("kubernetesServiceAccountName", k8s_service_account.metadata.name)

