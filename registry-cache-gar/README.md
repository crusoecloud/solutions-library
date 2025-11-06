# registry-cache

This is a working solution of an OCI Image registry that acts as a cache for an upstream [Google Artifact Registry](https://docs.cloud.google.com/artifact-registry/docs). The image registry runs in Kubernetes.

## Key features
* Uses CNCF Distribution registry (aka `registry:3`)
* Uses [Google Workload Identity Federation](https://docs.cloud.google.com/iam/docs/workload-identity-federation) to authenticate against the upstream Google Artifact Registry
* Stateless, best-effort caching proxy. Can run any number of replicas
* Supports requiring auth to the in-cache registry itself

## Installation/Deployment
### 1. Build the registry docker image
This project uses a custom docker image that is mostly the upstream `registry:3` image, but includes [docker-credential-gcr](https://github.com/GoogleCloudPlatform/docker-credential-gcr/). The built assets available in that GitHub repo are compiled against glibc, but `registry:3` is based on musl. So there is a small Dockerfile in this code called `Dockerfile.docker-credential-gcr` that compiles it from scratch for a full image.

For an easy demo I have this image available at `docker.io/bchess/registry-docker-credential-gcr:3.0`, but you should build and host it yourself.

`podman build -f Dockerfile.docker-credential-gcr -t <YOUR_DOCKER_IMAGE_TAG> .`

`podman push <YOUR_DOCKER_IMAGE_TAG>`

You may be wondering: "_Can I host this image in the same Google Artifact Registry that I'm trying to proxy from?_" The answer is... not easily. Because that
Google Artifact Registry requires authentication, there needs to be an imagePullSecret to read images from it. And Workload Identity Federation tokens are temporary, so you'd need some mechanism to periodically be refreshing that token. This registry proxy solution provides that, but there's a chicken-and-egg to it.  For that reason, I recommend that you store this image in a separate repo that does not require authentication.

### 2. Pulumi
The `registry-cache` subdirectory is a pulumi project that deploys all necessary pieces. Some modifications may be necessary to fit your specific needs.

1. [Install pulumi](https://www.pulumi.com/docs/get-started/download-install/)
2. Fill out the mising variables in `Pulumi.prod.yaml`
3. Ensure you have working access to your kubernetes cluster via `kubectl` and access to Google Cloud via `gcloud auth login`
4. `pulumi up`

## Usage
Once deployed, you will have a `NodePort` Service in your Kubernetes cluster that reaches the in-cluster caching proxy. (The Service must be a `NodePort` so that containerd, which runs on the host and thus isn't controlled by a CNI, can reach the service)

### Update image refs
Update your `image:` to swap out the upstream domain of `us-central1-docker.pkg.dev` with `localhost:<REGISTRY_NODE_PORT>` where `REGISTRY_NODE_PORT` is set to the `registryNodePort` value you specified in `Pulumi.prod.yaml`

e.g. if your `image:` is otherwise set to `us-central1-docker.pkg.dev/bchess-123/my-repo/busybox:1.37`,  and `registryNodePort` is set to `30026`, then change the image to `localhost:30026/bchess-123/my-repo/busybox:1.37`

### imagePullSecret
The registry itself requires auth as defined in the `registryHtpasswd` config value. You must create an image pull secret that has these credentials, e.g.:

    {
      "auths": {
        "localhost:30026": {
          "auth": "bXl1c2VybmFtZTpteXBhc3N3b3Jk"  # base64-encoded myusername:mypassword that matches the htpasswd
        }
      }
    }


Or, via kubectl:

`kubectl create secret docker-registry my-pull-secret --docker-server=localhost:30026 --docker-username=myusername --docker-password=mypassword`