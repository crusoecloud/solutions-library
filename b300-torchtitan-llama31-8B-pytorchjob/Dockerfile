#   DOCKER_BUILDKIT=1 docker build \
#     --secret id=hf_token,env=HF_TOKEN \
#     -t <REGISTRY>/torchtitan-llama3-8b:latest .
#
#   docker push <REGISTRY>/torchtitan-llama3-8b:latest
#

FROM docker.io/abesharphpe/nccl-tests:13.0.2-devel-ubuntu24.04-nccl2.30.3

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    python3 \
    python3-venv \
    ca-certificates libnccl2 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

RUN git clone --branch release-v0.2.2 --depth 1 \
    https://github.com/crusoecloud/torchtitan.git /workspace/torchtitan

WORKDIR /workspace/torchtitan

RUN uv venv /workspace/venv

ENV VIRTUAL_ENV=/workspace/venv
ENV PATH="/workspace/venv/bin:$PATH"

RUN uv pip install --no-cache \
    torch \
    torchvision \
    torchaudio \
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

RUN uv pip install --pre torch --index-url https://download.pytorch.org/whl/nightly/cu130 --force-reinstall
RUN uv pip install --pre torchtitan --index-url https://download.pytorch.org/whl/nightly/cu130

RUN --mount=type=secret,id=hf_token \
    python scripts/download_hf_assets.py \
        --repo_id meta-llama/Llama-3.1-8B \
        --hf_token "$(cat /run/secrets/hf_token)" \
        --local_dir assets/hf \
        --assets tokenizer config
