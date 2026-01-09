# c4c2w - Container for Container2Wasm
# Base: Official Docker-in-Docker image (no openrc dance needed)
FROM docker:27-dind

# Tools for config parsing and file operations
RUN apk add --no-cache \
    bash \
    curl \
    git \
    jq \
    yq \
    tar \
    gzip \
    coreutils \
    fuse-overlayfs \
    ca-certificates

# Install container2wasm (c2w + c2w-net)
# Detect architecture and download appropriate binary
ARG C2W_VERSION=v0.8.3
RUN ARCH=$(uname -m) && \
    case "$ARCH" in \
        x86_64) C2W_ARCH="amd64" ;; \
        aarch64) C2W_ARCH="arm64" ;; \
        *) echo "Unsupported architecture: $ARCH" && exit 1 ;; \
    esac && \
    curl -fsSL -o /tmp/c2w.tgz \
        "https://github.com/ktock/container2wasm/releases/download/${C2W_VERSION}/container2wasm-${C2W_VERSION}-linux-${C2W_ARCH}.tar.gz" \
 && tar -xzf /tmp/c2w.tgz -C /usr/local/bin c2w c2w-net \
 && rm -f /tmp/c2w.tgz \
 && chmod +x /usr/local/bin/c2w /usr/local/bin/c2w-net

# Docker daemon config: use vfs storage driver for maximum compatibility in nested Docker
# (slower but works reliably in DinD scenarios)
RUN mkdir -p /etc/docker \
 && printf '{\n  "storage-driver": "vfs"\n}\n' > /etc/docker/daemon.json

WORKDIR /work

COPY config.yaml /work/config.yaml
COPY entrypoint.sh /work/entrypoint.sh
RUN chmod +x /work/entrypoint.sh

# /out will be a bind mount from host
VOLUME ["/out"]

ENTRYPOINT ["/work/entrypoint.sh"]

