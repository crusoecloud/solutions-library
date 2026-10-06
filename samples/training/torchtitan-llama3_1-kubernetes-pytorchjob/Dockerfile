# The HF token is never written to an image layer — export your HF_TOKEN
# and pass it as a BuildKit secret:
#
#   DOCKER_BUILDKIT=1 docker build \
#     --secret id=hf_token,env=HF_TOKEN \
#     -f Dockerfile.ngc \
#     -t <YOUR REGISTRY>/torchtitan-llama3-8b:latest .
#
#   docker push <YOUR REGISTRY>/torchtitan-llama3-8b:latest

FROM nvcr.io/nvidia/pytorch:26.03-py3

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    infiniband-diags \
    wget \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --branch release-v0.2.2 --depth 1 \
    https://github.com/crusoecloud/torchtitan.git /workspace/torchtitan

WORKDIR /workspace/torchtitan

RUN pip install --root-user-action ignore --no-cache-dir \
    "torchdata>=0.8.0" \
    "datasets>=3.6.0" \
    "tokenizers>=0.15.0" \
    "tomli>=1.1.0" \
    tensorboard \
    tabulate \
    fsspec \
    tyro \
    einops \
    pillow \
    safetensors \
    boto3 \
    huggingface_hub

RUN --mount=type=secret,id=hf_token \
    python scripts/download_hf_assets.py \
        --repo_id meta-llama/Llama-3.1-8B \
        --hf_token "$(cat /run/secrets/hf_token)" \
        --local_dir assets/hf \
        --assets tokenizer config


RUN --mount=type=secret,id=hf_token \
    python scripts/download_hf_assets.py \
        --repo_id meta-llama/Llama-3.1-70B \
        --hf_token "$(cat /run/secrets/hf_token)" \
        --local_dir assets/hf \
        --assets tokenizer config

RUN --mount=type=secret,id=hf_token \
    python scripts/download_hf_assets.py \
        --repo_id meta-llama/Llama-3.1-405B \
        --hf_token "$(cat /run/secrets/hf_token)" \
        --local_dir assets/hf \
        --assets tokenizer config
