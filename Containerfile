ARG NIX_GIT_TAG=2.34.7

# Build the official nixos/nix Docker image from scratch.
#
# Stage 1: Install Nix, then use it to build the official docker.nix.
# Pinned to Ubuntu 26.04 LTS by digest for reproducibility. 26.04 ships
# boost 1.90 and curl 8.18 — both satisfy Nix's compile-time requirements.
FROM ubuntu:26.04@sha256:f3d28607ddd78734bb7f71f117f3c6706c666b8b76cbff7c9ff6e5718d46ff64 AS nix-builder

# ------------------------------------------------------------------
# Base dependencies
# ------------------------------------------------------------------
RUN apt-get update && apt-get install -y \
    curl \
    xz-utils \
    git \
    && rm -rf /var/lib/apt/lists/*

# ------------------------------------------------------------------
# Install Nix (single-user, no systemd needed)
# ------------------------------------------------------------------
ARG NIX_INSTALLER_URL=https://nixos.org/nix/install
ARG NIX_INSTALLER_HASH=e9d447ce3d2ff62d7ff9cb6ef401de6fa8acb148839dd00f7271945d7b638b14

RUN curl --proto '=https' --tlsv1.2 -fsSL -o /tmp/nix-install.sh "${NIX_INSTALLER_URL}" \
    && echo "${NIX_INSTALLER_HASH}  /tmp/nix-install.sh" | sha256sum -c

# Pre-create /nix as root so the installer doesn't try (and fail) to use sudo.
# The nixbld group must exist and have members: the Nix binary checks
# build-users-group during `nix-env -i` and requires at least one member.
RUN mkdir -m 0755 /nix \
    && groupadd -r nixbld \
    && for i in $(seq 1 32); do \
           useradd -r -g nixbld -d /var/empty -s /usr/sbin/nologin "nixbld$i"; \
       done

# Provide a minimal config before install so the Nix binary doesn't enforce
# build-users-group membership during `nix-env -i`.
RUN mkdir -p /etc/nix && echo "build-users-group =" > /etc/nix/nix.conf

ENV PATH=/root/.nix-profile/bin:$PATH

# --no-daemon performs a single-user install. In Docker there is no systemd,
# so the multi-user (daemon) mode is neither needed nor supported.
RUN sh /tmp/nix-install.sh --no-daemon

# ------------------------------------------------------------------
# Nix configuration for building
# ------------------------------------------------------------------
RUN mkdir -p /root/.config/nix
# nix-command and flakes enable `nix build '.#dockerImage'`
RUN echo "experimental-features = nix-command flakes" > /root/.config/nix/nix.conf
# sandbox=false: Docker containers often lack user-namespace capabilities
# that the Nix sandbox requires; disabling avoids build failures.
RUN echo "sandbox = false" >> /root/.config/nix/nix.conf

# ------------------------------------------------------------------
# Clone Nix repo at pinned version
# ------------------------------------------------------------------
ARG NIX_GIT_TAG

RUN git clone https://github.com/NixOS/nix.git /build/nix \
    && cd /build/nix \
    && git checkout "${NIX_GIT_TAG}"

# ------------------------------------------------------------------
# Build the official Docker image via nixpkgs + docker.nix
# ------------------------------------------------------------------
WORKDIR /build/nix

RUN nix build '.#dockerImage'

# ------------------------------------------------------------------
# Extract the resulting image.tar.gz to a flat path
# ------------------------------------------------------------------
RUN ls -la result/ && cp -L result/image.tar.gz /tmp/image.tar.gz

# Stage 2: scratch stage holds just the artifact
FROM scratch AS artifact
COPY --from=nix-builder /tmp/image.tar.gz /image.tar.gz

# Stage 3: validate the built image against an official reference
FROM golang:1.23-alpine AS validate

# NIX_VERSION=2.34.7
ENV REFERENCE_IMAGE=docker.io/nixos/nix@sha256:bf1d938835ab96312f098fa6c2e9cab367728e0aad0646ee3e02a787c80d8fb8

RUN apk add --no-cache skopeo bash

COPY --from=nix-builder /tmp/image.tar.gz /tmp/image.tar.gz
COPY scripts/prepare-images.sh /tmp/prepare-images.sh
COPY scripts/compare.go /tmp/compare.go

WORKDIR /tmp
RUN bash /tmp/prepare-images.sh /tmp/image.tar.gz "${REFERENCE_IMAGE}" /tmp/compare

# re-tag image
ARG NIX_GIT_TAG
RUN skopeo copy docker-archive:/tmp/image.tar.gz docker-archive:/tmp/retagged.tar.gz:local-nix:${NIX_GIT_TAG}
