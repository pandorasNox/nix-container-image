#!/usr/bin/env bash

set -o errexit
set -o nounset
# set -o xtrace

if set +o | grep -F 'set +o pipefail' > /dev/null; then
  # shellcheck disable=SC3040
  set -o pipefail
fi

if set +o | grep -F 'set +o posix' > /dev/null; then
  # shellcheck disable=SC3040
  set -o posix
fi

# -----------------------------------------------------------------------------

#SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
SCRIPT_DIR=$(dirname "$0"); SCRIPT_DIR=$(eval "cd \"${SCRIPT_DIR}\" && pwd")
echo "SCRIPT_DIR: ${SCRIPT_DIR}"

# -----------------------------------------------------------------------------

NIX_GIT_TAG="${1:-2.34.7}"
OUTPUT_DIR="${2:-.}"
# Tag-based reference is fine; the comparison resolves through the index.
REFERENCE_IMAGE="${3:-nixos/nix:${NIX_GIT_TAG}}"

if ! command -v docker &>/dev/null; then
    echo "Error: docker is required but not found." >&2
    exit 1
fi

VALIDATE_TAG="nix-validate:${NIX_GIT_TAG}"

echo "=== Building Nix Docker image (version ${NIX_GIT_TAG}) ==="
echo "This will take a long time on the first run (compiling Nix from source)."
echo

# Build the full pipeline: nix-builder → validate
docker build \
    --target validate \
    --build-arg "NIX_GIT_TAG=${NIX_GIT_TAG}" \
    --build-arg "REFERENCE_IMAGE=${REFERENCE_IMAGE}" \
    -t "${VALIDATE_TAG}" \
    -f "${SCRIPT_DIR}/Containerfile" \
    "${SCRIPT_DIR}"

# Extract artifacts from the validate image
echo
echo "=== Extracting artifacts ==="
mkdir -p "${OUTPUT_DIR}/dist"
CONTAINER_ID=$(docker create "${VALIDATE_TAG}")
docker cp "${CONTAINER_ID}:/tmp/image.tar.gz" "${OUTPUT_DIR}/dist/image.tar.gz"
docker cp "${CONTAINER_ID}:/tmp/retagged.tar.gz" "${OUTPUT_DIR}/dist/retagged.tar.gz"
docker cp "${CONTAINER_ID}:/tmp/compare" "${OUTPUT_DIR}/dist/compare"
docker rm "${CONTAINER_ID}" > /dev/null

docker load -i "${OUTPUT_DIR}/dist/retagged.tar.gz"

echo
echo "=== Done ==="
echo "Image exported to: ${OUTPUT_DIR}/dist/image.tar.gz"
echo "Compare results:  ${OUTPUT_DIR}/dist/compare/result.compare.log"
echo "Run 'docker images nix' to verify it was loaded."
