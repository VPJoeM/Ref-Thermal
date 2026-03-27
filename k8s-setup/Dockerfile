FROM nvcr.io/nvidia/cuda:12.6.0-devel-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive

# base tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    ipmitool \
    bc \
    zip \
    unzip \
    curl \
    wget \
    openssh-client \
    pciutils \
    dmidecode \
    lm-sensors \
    gnupg2 \
    ca-certificates \
    apt-transport-https \
    && rm -rf /var/lib/apt/lists/*

# Dell OpenManage racadm (in-band via IPMI)
RUN echo 'deb http://linux.dell.com/repo/community/openmanage/11100/jammy jammy main' \
    > /etc/apt/sources.list.d/linux.dell.com.sources.list && \
    wget -qO - https://linux.dell.com/repo/pgp_pubkeys/0x1285491434D8786F.asc | apt-key add - 2>/dev/null && \
    apt-get update && \
    apt-get install -y --no-install-recommends racadm7 || \
    echo "WARNING: racadm install failed, will try at runtime" && \
    rm -rf /var/lib/apt/lists/*

# NVIDIA DCGM + dcgmproftester
RUN wget -qO /tmp/cuda-keyring.deb \
    https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb && \
    dpkg -i /tmp/cuda-keyring.deb && rm /tmp/cuda-keyring.deb && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
    datacenter-gpu-manager-4-cuda12 || \
    apt-get install -y --no-install-recommends datacenter-gpu-manager && \
    rm -rf /var/lib/apt/lists/*

# working directory for results
RUN mkdir -p /root/TDAS /results /opt/thermal-diagnostics

# copy in the thermal diagnostics script and entrypoint
COPY thermal-diagnostics-2.6.2-vp.sh /opt/thermal-diagnostics/thermal-diagnostics.sh
COPY entrypoint.sh /opt/thermal-diagnostics/entrypoint.sh
RUN chmod +x /opt/thermal-diagnostics/*.sh

WORKDIR /root/TDAS

ENTRYPOINT ["/opt/thermal-diagnostics/entrypoint.sh"]
