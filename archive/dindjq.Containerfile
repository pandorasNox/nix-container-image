FROM docker.io/library/docker:dind-rootless

USER root
RUN apk add --no-cache bash jq skopeo
USER rootless

#    0 export DOCKER_HOST=unix:///run/user/1000/docker.sock
#    1 docker ps
#    2 ls
#    3 docker load -i image.tar.gz
#    4 docker images
#    5 docker pull docker.io/nixos/nix@sha256:bf1d938835ab96312f098fa6c2e9cab367728e0aad0646ee3e02a787c80d8fb8
#    6 docker images
#    7 docker tag nix:2.34.7 nix:local
#    8 ./compare-image-layers.sh nix:local docker.io/nixos/nix@sha256:bf1d938835ab96312f098fa6c2e9cab367728e0aad0646ee3e02a787c80d8fb8
#    $  du -h compare-image-layers.local.tar.gz compare-image-layers.reference.tar.gz

# ./compare-image-layers.sh image.tar.gz docker.io/nixos/nix@sha256:bf1d938835ab96312f098fa6c2e9cab367728e0aad0646ee3e02a787c80d8fb8
# skopeo copy docker-archive:image.tar.gz dir:compare/test
# skopeo inspect --raw oci:compare/reference-oci | jq
# skopeo inspect --raw oci:compare/local-oci | jq

# Skopeo usage examples:
#   # Inspect remote image manifest (works without pulling layers):
#   skopeo inspect --raw docker://nixos/nix@sha256:bf1d9388... | jq .
#
#   # Copy local image from docker daemon to OCI directory:
#   skopeo copy docker-daemon:nix:local oci:local-oci:latest
#
#   # Copy reference image from registry to OCI directory (downloads all layers):
#   skopeo copy docker://nixos/nix@sha256:bf1d9388... oci:reference-oci:latest
#
#   # Compare layer sizes in the two OCI directories:
#   du -sh local-oci/blobs/sha256/* reference-oci/blobs/sha256/*
