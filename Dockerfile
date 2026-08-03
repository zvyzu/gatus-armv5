# syntax=docker/dockerfile:1

# ==========================================================================
# Stage 1: Build the gatus binary for ARMv5
# ==========================================================================
FROM debian:stable AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    pkg-config \
    ca-certificates \
    curl \
    tzdata \
    && rm -rf /var/lib/apt/lists/*

# Copy the Go toolchain built for ARMv5 (version auto-detected by build script)
# The filename is dynamic, so it is passed in via a build ARG.
ARG GO_TOOLCHAIN_TARBALL
COPY ${GO_TOOLCHAIN_TARBALL} /tmp/

RUN mkdir -p /usr/local/go && \
    tar -C /usr/local/go -xzf /tmp/${GO_TOOLCHAIN_TARBALL} && \
    if [ -d /usr/local/go/bin/linux_arm ]; then \
      mv -f /usr/local/go/bin/linux_arm/* /usr/local/go/bin/ && \
      rmdir /usr/local/go/bin/linux_arm; \
    fi && \
    rm /tmp/${GO_TOOLCHAIN_TARBALL}

ENV GOROOT=/usr/local/go
ENV PATH=$GOROOT/bin:$PATH
ENV GOPATH=/go
ENV GO111MODULE=on
ENV GOPROXY=https://proxy.golang.org,direct

# Use a build argument to specify the gatus version (e.g. "v5.36.0")
ARG GATUS_VERSION=master

RUN git clone https://github.com/TwiN/gatus.git /gatus

WORKDIR /gatus

# Checkout the specified version
RUN git checkout $GATUS_VERSION

# Ensure Go is executable
RUN chmod +x /usr/local/go/bin/go

RUN go mod download

# Build a fully static ARMv5 binary. gatus uses pure-Go (modernc.org/sqlite)
# and embeds its pre-built web assets, so no cgo / Node.js is needed.
RUN CGO_ENABLED=0 GOOS=linux GOARCH=arm GOARM=5 \
    go build -a -installsuffix cgo -o /gatus/gatus .

# Prepare a minimal passwd/group so the scratch image can run as non-root,
# and an empty, writable data directory for SQLite storage.
RUN mkdir -p /rootfs/etc /rootfs/data && \
    echo 'gatus:x:10001:10001:gatus:/data:/sbin/nologin' > /rootfs/etc/passwd && \
    echo 'gatus:x:10001:' > /rootfs/etc/group && \
    chown -R 10001:10001 /rootfs/data

# ==========================================================================
# Stage 2: Minimal runtime image (scratch)
# ==========================================================================
FROM scratch

# Run as a non-root user (static passwd/group prepared in the builder stage).
COPY --from=builder /rootfs/etc/passwd /etc/passwd
COPY --from=builder /rootfs/etc/group /etc/group

# Copy the static binary, default config, CA certs and timezone data.
COPY --from=builder /gatus/gatus /gatus
COPY --from=builder /gatus/config.yaml /config/config.yaml
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=builder /usr/share/zoneinfo /usr/share/zoneinfo

# Empty, writable data directory for SQLite storage (when enabled).
COPY --from=builder --chown=10001:10001 /rootfs/data /data

ENV GATUS_CONFIG_PATH=""
ENV GATUS_LOG_LEVEL="INFO"
ENV PORT="8080"
ENV TZ=UTC

USER 10001:10001

EXPOSE ${PORT}

ENTRYPOINT ["/gatus"]
