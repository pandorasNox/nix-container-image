#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

usage() {
    cat <<EOF
Prepare container images for comparison, then run the Go comparison tool.

Usage: $SCRIPT_NAME <local-tar-gz> <reference-image> [workdir]

Arguments:
  local-tar-gz     Path to the gzipped Docker image tarball from nix build.
  reference-image  Registry reference (with or without docker://).
  workdir          Working directory (default: \$(pwd)/compare).
EOF
    exit 1
}

LOCAL_GZ="${1:-}"
REFERENCE="${2:-}"
WORKDIR="${3:-$(pwd)/compare}"

[ -z "$LOCAL_GZ" ] || [ -z "$REFERENCE" ] && usage

for cmd in skopeo go tar; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: '$cmd' is required but not found." >&2
        exit 1
    fi
done

# Normalise reference
if [[ "$REFERENCE" != *"://"* ]]; then
    REFERENCE="docker://$REFERENCE"
fi

mkdir -p "$WORKDIR"
LOG="$WORKDIR/result.compare.log"

# Tee all output to both terminal and log
exec > >(tee -a "$LOG") 2>&1

LOCAL_TAR="$WORKDIR/local-image.tar"
LOCAL_OCI="$WORKDIR/local-oci"
REF_OCI="$WORKDIR/reference-oci"

# ── 1. Decompress local tar ──────────────────────────────────────────────
echo "  [1/3] Uncompressing local image: $LOCAL_GZ → $(basename "$LOCAL_TAR")"
if [[ "$LOCAL_GZ" == *.gz ]]; then
    gunzip -c "$LOCAL_GZ" > "$LOCAL_TAR"
else
    cp "$LOCAL_GZ" "$LOCAL_TAR"
fi
echo "    done  ($(stat -c%s "$LOCAL_TAR" 2>/dev/null || stat -f%z "$LOCAL_TAR") bytes)"
echo ""

# ── 2. Convert local to OCI layout ───────────────────────────────────────
echo "  [2/3] Converting local image to OCI layout..."
skopeo copy "docker-archive:$LOCAL_TAR" "oci:$LOCAL_OCI:latest" --quiet
echo "    done  → $LOCAL_OCI"
rm -f "$LOCAL_TAR"
echo ""

# ── 3. Download reference to OCI layout ──────────────────────────────────
echo "  [3/3] Downloading reference image to OCI layout..."
echo "        Source: $REFERENCE"
skopeo copy --multi-arch=all "$REFERENCE" "oci:$REF_OCI:latest" --quiet
echo "    done  → $REF_OCI"
echo ""

# ── 4. OCI tar.gz for size comparison ────────────────────────────────────
echo "  Creating compressed OCI archives for size comparison..."
tar czf "$WORKDIR/local-oci.tar.gz" -C "$WORKDIR" local-oci
tar czf "$WORKDIR/reference-oci.tar.gz" -C "$WORKDIR" reference-oci
echo "    done"
echo ""

# ── 5. Run Go comparison ─────────────────────────────────────────────────
echo "  Running comparison..."
echo ""
COMPARE_SCRIPT="$(dirname "$0")/compare.go"
if [ ! -f "$COMPARE_SCRIPT" ]; then
    COMPARE_SCRIPT="/tmp/compare.go"
fi

go run "$COMPARE_SCRIPT" \
    "$LOCAL_OCI" "$REF_OCI" \
    "$(basename "$LOCAL_GZ")" "$REFERENCE" \
    "$WORKDIR/local-oci.tar.gz" "$WORKDIR/reference-oci.tar.gz"

echo ""
echo "  Log written to: $LOG"
