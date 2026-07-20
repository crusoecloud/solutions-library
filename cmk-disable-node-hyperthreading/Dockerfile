FROM alpine:3.19

# util-linux provides nsenter; bash for the script; stress-ng for testing performance
# with and without hyperthreading
RUN apk add --no-cache util-linux bash curl stress-ng

# Install kubectl so that the pods can label their nodes when complete
# Pin to a specific kubectl version matching your cluster, or override at build time:
#   docker build --build-arg KUBECTL_VERSION=v1.30.0 .
ARG KUBECTL_VERSION=v1.35.0
RUN curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
      -o /usr/local/bin/kubectl \
    && chmod +x /usr/local/bin/kubectl
