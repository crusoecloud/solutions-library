# Build and push:
#   docker build -t <REGISTRY>/nccl-tests-b300:latest -f .
#   docker push <REGISTRY>/nccl-tests-b300:latest

FROM nvcr.io/nvidia/cuda:12.8.0-devel-ubuntu24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends gnupg2 curl \
    build-essential \
    git \
    ca-certificates \
    openssh-client \
    openssh-server \
    libopenmpi-dev \
    openmpi-bin \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /opt/amazon/openmpi/bin \
    && ln -sf /usr/bin/mpirun /opt/amazon/openmpi/bin/mpirun \
    && ln -sf /usr/bin/orted /opt/amazon/openmpi/bin/orted

RUN mkdir -p /var/run/sshd \
    && sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config \
    && sed -i 's/UsePAM yes/UsePAM no/' /etc/ssh/sshd_config \
    && echo "    StrictHostKeyChecking no" >> /etc/ssh/ssh_config

RUN git clone --depth 1 https://github.com/NVIDIA/nccl-tests.git /opt/nccl-tests \
    && cd /opt/nccl-tests \
    && make -j"$(nproc)" \
        CUDA_HOME=/usr/local/cuda \
        MPI=1 \
        MPI_HOME=/usr/lib/x86_64-linux-gnu/openmpi \
        NCCL_HOME=/usr \
        NVCC_GENCODE="-gencode=arch=compute_100,code=sm_100"

COPY b300-288gb-sxm-ib-cloud-hypervisor.xml /opt/nccl_topo/b300-288gb-sxm-ib-cloud-hypervisor.xml

EXPOSE 22

CMD ["/usr/sbin/sshd", "-D"]
