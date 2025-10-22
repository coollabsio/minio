# MinIO Dockerfile based on official build process
# Supports building from source for any release version

ARG MINIO_VERSION=latest
ARG TARGETARCH

# Build stage - compile MinIO from source
FROM golang:1.24-alpine AS builder

ARG MINIO_VERSION
ARG TARGETARCH

ENV GOPATH=/go
ENV CGO_ENABLED=0

WORKDIR /workspace

# Install build dependencies and minisign
RUN apk add -U --no-cache ca-certificates && \
    apk add -U --no-cache git && \
    apk add -U --no-cache make && \
    apk add -U --no-cache curl && \
    apk add -U --no-cache bash && \
    go install aead.dev/minisign/cmd/minisign@v0.2.1

# Clone MinIO source code at the specified version
RUN git clone https://github.com/minio/minio.git . && \
    if [ "$MINIO_VERSION" != "latest" ]; then \
        echo "Checking out version: $MINIO_VERSION" && \
        git checkout ${MINIO_VERSION}; \
    else \
        echo "Building from latest master"; \
    fi

# Get commit info for ldflags
RUN COMMIT_ID=$(git rev-parse --short HEAD) && \
    echo "Building MinIO version: $MINIO_VERSION commit: $COMMIT_ID"

# Build MinIO binary with proper version flags
RUN COMMIT_ID=$(git rev-parse --short HEAD) && \
    CGO_ENABLED=0 go build -trimpath \
    -ldflags "-s -w -X github.com/minio/minio/cmd.ReleaseTag=${MINIO_VERSION}" \
    -o /usr/bin/minio .

# Verify the binary works
RUN /usr/bin/minio --version

# Download MinIO Client (mc) binary and signature files
RUN curl -s -q https://dl.min.io/client/mc/release/linux-${TARGETARCH}/mc -o /usr/bin/mc && \
    curl -s -q https://dl.min.io/client/mc/release/linux-${TARGETARCH}/mc.minisig -o /usr/bin/mc.minisig && \
    curl -s -q https://dl.min.io/client/mc/release/linux-${TARGETARCH}/mc.sha256sum -o /usr/bin/mc.sha256sum && \
    chmod +x /usr/bin/mc

# Verify mc binary signature using MinIO public key
RUN /go/bin/minisign -Vqm /usr/bin/mc -x /usr/bin/mc.minisig -P RWTx5Zr1tiHQLwG9keckT0c45M3AGeHD6IvimQHpyRywVWGbP1aVSGav

# Verify mc binary works
RUN /usr/bin/mc --version


# Runtime stage - minimal image with MinIO binary
FROM registry.access.redhat.com/ubi9/ubi-micro:latest

ARG MINIO_VERSION
ARG TARGETARCH

LABEL name="MinIO" \
      vendor="MinIO Inc <dev@min.io>" \
      maintainer="MinIO Inc <dev@min.io>" \
      version="${MINIO_VERSION}" \
      release="${MINIO_VERSION}" \
      summary="MinIO is a High Performance Object Storage, API compatible with Amazon S3 cloud storage service." \
      description="MinIO object storage is fundamentally different. Designed for performance and the S3 API, it is 100% open-source. MinIO is ideal for large, private cloud environments with stringent security requirements and delivers mission-critical availability across a diverse range of workloads." \
      org.opencontainers.image.source="https://github.com/minio/minio" \
      org.opencontainers.image.version="${MINIO_VERSION}" \
      org.opencontainers.image.licenses="AGPL-3.0"

# Set permissions before copying
RUN chmod -R 777 /usr/bin

# Copy binaries and certificates from builder
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=builder /usr/bin/minio* /usr/bin/
COPY --from=builder /usr/bin/mc* /usr/bin/

# Copy license files
COPY --from=builder /workspace/CREDITS /licenses/CREDITS
COPY --from=builder /workspace/LICENSE /licenses/LICENSE

# Copy entrypoint script
COPY --from=builder /workspace/dockerscripts/docker-entrypoint.sh /usr/bin/docker-entrypoint.sh

# Environment variables for MinIO configuration
ENV MINIO_ACCESS_KEY_FILE=access_key \
    MINIO_SECRET_KEY_FILE=secret_key \
    MINIO_ROOT_USER_FILE=access_key \
    MINIO_ROOT_PASSWORD_FILE=secret_key \
    MINIO_KMS_SECRET_KEY_FILE=kms_master_key \
    MINIO_UPDATE_MINISIGN_PUBKEY="RWTx5Zr1tiHQLwG9keckT0c45M3AGeHD6IvimQHpyRywVWGbP1aVSGav" \
    MINIO_CONFIG_ENV_FILE=config.env \
    MC_CONFIG_DIR=/tmp/.mc

# Expose MinIO ports
# 9000: S3 API
# 9001: Web Console
EXPOSE 9000 9001

# Data volume
VOLUME ["/data"]

ENTRYPOINT ["/usr/bin/docker-entrypoint.sh"]
CMD ["minio"]
