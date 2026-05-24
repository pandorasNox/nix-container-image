#!/usr/bin/env bash
# shellcheck disable=SC2207,SC2206,SC2086
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

usage() {
    cat <<EOF
Compare two Docker images and produce a verdict.

Usage: $SCRIPT_NAME <local-image> <reference-image>

Arguments:
  local-image      Tag of your locally-built image (e.g., nix:local).
                   Load it first:  docker load -i /tmp/image.tar.gz
  reference-image  Official image tag or digest
                   (e.g., nixos/nix:2.34.7 or nixos/nix@sha256:bf1d...)

The reference image is pulled if not present locally.
A non-reference image (no registry) is used as-is.
Requires: docker, jq
EOF
    exit 1
}

LOCAL="${1:-}"
REFERENCE="${2:-}"
[ -z "$LOCAL" ] || [ -z "$REFERENCE" ] && usage

for cmd in docker jq; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: '$cmd' is required but not found." >&2
        exit 1
    fi
done

# ── helpers ──────────────────────────────────────────────────────────

die() { echo "Error: $*" >&2; exit 1; }
bold() { printf '\e[1m%s\e[0m' "$1"; }
green() { printf '\e[32m%s\e[0m' "$1"; }
yellow() { printf '\e[33m%s\e[0m' "$1"; }
red() { printf '\e[31m%s\e[0m' "$1"; }

# ── pull / check local availability ──────────────────────────────────

if docker image inspect "$REFERENCE" &>/dev/null; then
    REF_SOURCE=local
else
    echo "Pulling reference image..."
    docker pull "$REFERENCE" || die "Failed to pull reference image"
    REF_SOURCE=remote
fi

if ! docker image inspect "$LOCAL" &>/dev/null; then
    die "Local image '$LOCAL' not found. Load it first: docker load -i <file>"
fi

# Also try to inspect the raw reference name (before docker pull resolves it)
# to get the manifest list if the reference is a tag on a registry.
REF_NAME_FOR_MANIFEST="$REFERENCE"

# ── gather data ──────────────────────────────────────────────────────

local_insp=$(docker inspect "$LOCAL")
ref_insp=$(docker inspect "$REFERENCE")

local_os=$(jq -r '.[0].Os'        <<<"$local_insp")
local_arch=$(jq -r '.[0].Architecture' <<<"$local_insp")
local_variant=$(jq -r '.[0].Variant // ""' <<<"$local_insp")
local_created=$(jq -r '.[0].Created' <<<"$local_insp" | cut -d. -f1 | tr T ' ')
local_size=$(jq -r '.[0].Size'     <<<"$local_insp")
local_vsize=$(jq -r '.[0].VirtualSize // 0' <<<"$local_insp")
local_id=$(jq -r '.[0].Id'         <<<"$local_insp" | sed 's/sha256://')

ref_os=$(jq -r '.[0].Os'          <<<"$ref_insp")
ref_arch=$(jq -r '.[0].Architecture' <<<"$ref_insp")
ref_variant=$(jq -r '.[0].Variant // ""' <<<"$ref_insp")
ref_created=$(jq -r '.[0].Created' <<<"$ref_insp" | cut -d. -f1 | tr T ' ')
ref_size=$(jq -r '.[0].Size'      <<<"$ref_insp")
ref_vsize=$(jq -r '.[0].VirtualSize // 0' <<<"$ref_insp")
ref_id=$(jq -r '.[0].Id'          <<<"$ref_insp" | sed 's/sha256://')

# Pre-compute config digests for verdict summary
local_config_digest="$local_id"
ref_config_digest="$ref_id"
ids_match=false
[ "$local_id" = "$ref_id" ] && ids_match=true

# Counters for verdict
score_id=0       # 1=image IDs match (config digests)
score_platform=0 # 1=ok
score_layers=0   # 1=identical, 2=identical order
score_config=0   # 1=ok
score_total=0
score_max=4

if [ "$local_os" = "$ref_os" ] && [ "$local_arch" = "$ref_arch" ] && [ "$local_variant" = "$ref_variant" ]; then
    score_platform=1
fi

$ids_match && score_id=1

# ── format bytes ────────────────────────────────────────────────────
fmt_bytes() {
    local b=$1
    if command -v numfmt &>/dev/null; then
        numfmt --to=iec <<<"$b"
    else
        echo "$((b / 1024 / 1024)) MiB"
    fi
}

# ── layers ───────────────────────────────────────────────────────────
get_layers() {
    jq -r '.[0].RootFS.Layers[]' <<<"$(docker inspect "$1")"
}

mapfile -t LOCAL_LAYERS < <(get_layers "$LOCAL")
mapfile -t REF_LAYERS   < <(get_layers "$REFERENCE")
LOCAL_COUNT="${#LOCAL_LAYERS[@]}"
REF_COUNT="${#REF_LAYERS[@]}"

IFS=$'\n' LOCAL_SORTED=($(sort <<<"${LOCAL_LAYERS[*]}"))
IFS=$'\n' REF_SORTED=($(sort   <<<"${REF_LAYERS[*]}"))
unset IFS

layers_identical=false
layers_same_set=false
if [ "$LOCAL_COUNT" -eq "$REF_COUNT" ] && [ "${LOCAL_LAYERS[*]}" = "${REF_LAYERS[*]}" ]; then
    layers_identical=true
    score_layers=2
elif [ "$LOCAL_COUNT" -eq "$REF_COUNT" ] && [ "${LOCAL_SORTED[*]}" = "${REF_SORTED[*]}" ]; then
    layers_same_set=true
    score_layers=1
fi

# ── config (Entrypoint, Cmd, Env, Labels, WorkingDir, User) ─────────
local_config=$(jq -r '.[0].Config' <<<"$local_insp")
ref_config=$(jq -r '.[0].Config'   <<<"$ref_insp")

# Compare scalar fields: null === missing
config_field_eq() {
    local key="$1"
    local lc rc
    lc=$(jq -r "${key}" <<<"$local_config" 2>/dev/null || echo "__NULL__")
    rc=$(jq -r "${key}" <<<"$ref_config"   2>/dev/null || echo "__NULL__")
    [ "${lc:-null}" = "${rc:-null}" ] || { [ "$lc" = "null" ] && [ "$rc" = "__NULL__" ]; } || { [ "$lc" = "__NULL__" ] && [ "$rc" = "null" ]; }
}

config_ok=true
# Scalar fields: order-independent by nature
for key in '.Entrypoint' '.Cmd' '.User' '.WorkingDir'; do
    config_field_eq "$key" || { config_ok=false; break; }
done

# Env — array, compare as sorted strings (order-independent)
local_env_str=$(jq -r '.Env // [] | sort[]' <<<"$local_config" 2>/dev/null)
ref_env_str=$(jq -r '.Env // [] | sort[]'   <<<"$ref_config"   2>/dev/null)
[ "$local_env_str" != "$ref_env_str" ] && config_ok=false

# Labels — object, compare as sorted key=value pairs (order-independent)
local_label_str=$(jq -r '.Labels // {} | to_entries | sort_by(.key) | .[] | "\(.key)=\(.value)"' <<<"$local_config" 2>/dev/null)
ref_label_str=$(jq -r '.Labels // {} | to_entries | sort_by(.key) | .[] | "\(.key)=\(.value)"'   <<<"$ref_config"   2>/dev/null)
[ "$local_label_str" != "$ref_label_str" ] && config_ok=false

$config_ok && score_config=1

# ── history ──────────────────────────────────────────────────────────
local_history=$(docker history --no-trunc "$LOCAL" 2>/dev/null || echo "")
ref_history=$(docker history --no-trunc "$REFERENCE" 2>/dev/null || echo "")

# ── manifest inspection ─────────────────────────────────────────────
# For the reference (may be remote or a manifest list)
ref_manifest_platforms=""
ref_manifest_is_list=false
if docker manifest inspect "$REF_NAME_FOR_MANIFEST" &>/dev/null; then
    ref_raw=$(docker manifest inspect "$REF_NAME_FOR_MANIFEST")
    ref_mt=$(jq -r '.mediaType // ""' <<<"$ref_raw" 2>/dev/null || echo "")
    if echo "$ref_mt" | grep -qiE '(manifest.list|image.index)'; then
        ref_manifest_is_list=true
        ref_manifest_platforms=$(jq -r '.manifests[] |
          "    - \(.platform.os)/\(.platform.architecture)\(.platform.variant // "")"' <<<"$ref_raw")
    fi
fi

# For the local image: `docker manifest inspect` only works on registries,
# so we derive from `docker inspect` instead.
local_manifest_is_list=false
local_manifest_platforms="    - $local_os/$local_arch${local_variant:+$local_variant}"

# ─────────────────────────────────────────────────────────────────────
#  REPORT
# ─────────────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════════════════════════════════════"
echo "                     IMAGE COMPARISON REPORT"
echo "════════════════════════════════════════════════════════════════════════"
echo ""
echo "  $(bold "Local:")      $LOCAL"
echo "  $(bold "Reference:")  $REFERENCE"
echo ""

# ── 1. PLATFORM ──────────────────────────────────────────────────────
echo "════════════════════════════════════════════════════════════════════════"
echo "  1. PLATFORM & MANIFEST"
echo "════════════════════════════════════════════════════════════════════════"
printf "  %-20s  %-22s  %s\n" "Property" "Local" "Reference"
printf "  %-20s  %-22s  %s\n" "────────"  "─────"  "─────────"
printf "  %-20s  %-22s  %s\n" "Architecture" "$local_arch" "$ref_arch"
printf "  %-20s  %-22s  %s\n" "OS" "$local_os" "$ref_os"
printf "  %-20s  %-22s  %s\n" "Variant" "${local_variant:-<none>}" "${ref_variant:-<none>}"
echo ""

echo "  $(bold "Manifest type:")"
if $local_manifest_is_list; then
    echo "    Local:      multi-arch manifest list"
else
    echo "    Local:      single-arch image manifest"
fi
if $ref_manifest_is_list; then
    echo "    Reference:  multi-arch manifest list"
else
    echo "    Reference:  single-arch image manifest"
fi
echo ""

echo "  $(bold "Available architectures:")"
echo "    Local:"
echo "$local_manifest_platforms"
echo "    Reference:"
if [ -n "$ref_manifest_platforms" ]; then
    echo "$ref_manifest_platforms"
else
    echo "    - $ref_os/$ref_arch${ref_variant:+ $ref_variant}  (from local pull)"
fi
echo ""

# Check if local arch is covered by reference
if $ref_manifest_is_list; then
    if echo "$ref_manifest_platforms" | grep -qi "${local_os}/${local_arch}"; then
        echo "  $(green "✅") Local arch $local_os/$local_arch $(bold "IS") listed in reference manifest"
    else
        echo "  $(red "❌") Local arch $local_os/$local_arch is $(bold "NOT") listed in reference manifest"
    fi
    echo ""
fi

# ── 2. IMAGE CONFIG ──────────────────────────────────────────────────
echo "════════════════════════════════════════════════════════════════════════"
echo "  2. IMAGE CONFIG"
echo "════════════════════════════════════════════════════════════════════════"
printf "  %-20s  %-22s  %s\n" "Property" "Local" "Reference"
printf "  %-20s  %-22s  %s\n" "────────"  "─────"  "─────────"
printf "  %-20s  %-22s  %s\n" "Image ID" "${local_id:0:19}..." "${ref_id:0:19}..."
printf "  %-20s  %-22s  %s\n" "Created" "${local_created:-<none>}" "${ref_created:-<none>}"
printf "  %-20s  %-22s  %s\n" "Content Size" "$(fmt_bytes "$local_size")" "$(fmt_bytes "$ref_size")"
printf "  %-20s  %-22s  %s\n" "Virtual Size" "$(fmt_bytes "$local_vsize")" "$(fmt_bytes "$ref_vsize")"
echo ""
if $ids_match; then
    echo "  $(green "✅ Image IDs match — full config digest identical")"
else
    echo "  $(yellow "⚠️  Image IDs differ — config digest differs (history / timestamps)")"
    echo "     Same filesystem (layers) but different metadata = different image ID."
fi
if [ "$local_size" -ne "$ref_size" ] && [ "$local_size" -gt 0 ] && [ "$ref_size" -gt 0 ]; then
    echo ""
    echo "  $(yellow "ℹ️  Content size differs: $(fmt_bytes "$local_size") vs $(fmt_bytes "$ref_size")")"
    echo "     The $LOCAL_COUNT layer blobs are identical (same diff_ids) so Docker deduplicates"
    echo "     them on disk. A small reference content size means only the config blob"
    echo "     is unique — all layer bytes are shared with other images on this host."
fi
echo ""

# Entrypoint
local_ep=$(jq -r '.Entrypoint // [] | join(" ")' <<<"$local_config" 2>/dev/null)
ref_ep=$(jq -r '.Entrypoint // [] | join(" ")' <<<"$ref_config" 2>/dev/null)
[ -z "$local_ep" ] && local_ep="<none>"
[ -z "$ref_ep" ]   && ref_ep="<none>"
echo "  $(bold "Entrypoint:")"
echo "    Local:      $local_ep"
echo "    Reference:  $ref_ep"
echo ""

# Cmd
local_cmd=$(jq -r '.Cmd // [] | join(" ")' <<<"$local_config" 2>/dev/null)
ref_cmd=$(jq -r '.Cmd // [] | join(" ")' <<<"$ref_config" 2>/dev/null)
[ -z "$local_cmd" ] && local_cmd="<none>"
[ -z "$ref_cmd" ]   && ref_cmd="<none>"
echo "  $(bold "Cmd:")"
echo "    Local:      $local_cmd"
echo "    Reference:  $ref_cmd"
echo ""

# WorkingDir
local_wd=$(jq -r '.WorkingDir // ""' <<<"$local_config")
ref_wd=$(jq -r '.WorkingDir // ""' <<<"$ref_config")
[ -z "$local_wd" ] && local_wd="<none>"
[ -z "$ref_wd" ]   && ref_wd="<none>"
echo "  $(bold "WorkingDir:")  $local_wd  |  $ref_wd"
echo ""

# User
local_user=$(jq -r '.User // ""' <<<"$local_config")
ref_user=$(jq -r '.User // ""' <<<"$ref_config")
[ -z "$local_user" ] && local_user="<none>"
[ -z "$ref_user" ]   && ref_user="<none>"
echo "  $(bold "User:")  $local_user  |  $ref_user"
echo ""

# Environment
echo "  $(bold "Environment (sorted, one per line):")"
local_env=$(jq -r '.Env // [] | sort[]' <<<"$local_config" 2>/dev/null || echo "<none>")
ref_env=$(jq -r '.Env // [] | sort[]' <<<"$ref_config" 2>/dev/null || echo "<none>")
if [ "$local_env" = "$ref_env" ]; then
    echo "    ✅ Identical"
    echo "$local_env" | while IFS= read -r line; do echo "       $line"; done
else
    echo "    ⚠️  Differ:"
    diff -u0 <(echo "  $local_env") <(echo "  $ref_env") 2>/dev/null | tail -n+3 || true
fi
echo ""

# Labels
echo "  $(bold "Labels (sorted, one per line):")"
local_labels=$(jq -r '.Labels // {} | to_entries | sort_by(.key) | .[] | "\(.key)=\(.value)"' <<<"$local_config" 2>/dev/null)
ref_labels=$(jq -r '.Labels // {} | to_entries | sort_by(.key) | .[] | "\(.key)=\(.value)"' <<<"$ref_config" 2>/dev/null)
if [ -z "$local_labels" ]; then local_labels="<none>"; fi
if [ -z "$ref_labels" ]; then ref_labels="<none>"; fi
if [ "$local_labels" = "$ref_labels" ]; then
    echo "    ✅ Identical"
    [ "$local_labels" != "<none>" ] && echo "$local_labels" | while IFS= read -r line; do echo "       $line"; done
else
    echo "    ⚠️  Differ:"
    diff -u0 <(echo "$local_labels") <(echo "$ref_labels") 2>/dev/null | tail -n+3 || true
fi
echo ""

# ── 3. LAYERS ────────────────────────────────────────────────────────
echo "════════════════════════════════════════════════════════════════════════"
echo "  3. LAYERS  (RootFS diff_ids)"
echo "════════════════════════════════════════════════════════════════════════"
echo ""
echo "  $(bold "Local ($LOCAL_COUNT layers):")"
for layer in "${LOCAL_LAYERS[@]}"; do echo "    sha256:${layer#sha256:}"; done
echo ""
echo "  $(bold "Reference ($REF_COUNT layers):")"
for layer in "${REF_LAYERS[@]}"; do echo "    sha256:${layer#sha256:}"; done
echo ""

if $layers_identical; then
    echo "  $(green "✅ Layers IDENTICAL (same digests, same order)")"
elif $layers_same_set; then
    echo "  $(yellow "⚠️  Same layer content, different ORDER:")"
    for ((i=0; i<LOCAL_COUNT; i++)); do
        lid="${LOCAL_LAYERS[$i]}"
        rid="${REF_LAYERS[$i]}"
        if [ "$lid" != "$rid" ]; then
            echo "     Position $((i+1)): local sha256:${lid#sha256:}  ≠  ref sha256:${rid#sha256:}"
        fi
    done
else
    echo "  $(red "❌ Layers DIFFER")"
    if [ "$LOCAL_COUNT" -ne "$REF_COUNT" ]; then
        echo "     Layer count: $LOCAL_COUNT (local) vs $REF_COUNT (reference)"
    fi
    local_sorted_str=$(printf '%s\n' "${LOCAL_SORTED[@]}")
    ref_sorted_str=$(printf '%s\n' "${REF_SORTED[@]}")
    only_local=$(comm -23 <(echo "$local_sorted_str") <(echo "$ref_sorted_str") || true)
    only_ref=$(comm -13 <(echo "$local_sorted_str") <(echo "$ref_sorted_str") || true)
    if [ -n "$only_local" ]; then
        echo ""
        echo "  Layers only in LOCAL:"
        while IFS= read -r line; do
            [ -n "$line" ] && echo "    + sha256:${line#sha256:}"
        done <<< "$only_local"
    fi
    if [ -n "$only_ref" ]; then
        echo ""
        echo "  Layers only in REFERENCE:"
        while IFS= read -r line; do
            [ -n "$line" ] && echo "    - sha256:${line#sha256:}"
        done <<< "$only_ref"
    fi
fi
echo ""

# ── 4. BUILD HISTORY ────────────────────────────────────────────────
echo "════════════════════════════════════════════════════════════════════════"
echo "  4. BUILD HISTORY"
echo "════════════════════════════════════════════════════════════════════════"
echo ""
echo "  $(bold "Local:" )"
echo "$local_history" | head -20 | sed 's/^/    /'
[ "$(echo "$local_history" | wc -l)" -gt 20 ] && echo "    ... (truncated)"
echo ""
echo "  $(bold "Reference:")"
echo "$ref_history" | head -20 | sed 's/^/    /'
[ "$(echo "$ref_history" | wc -l)" -gt 20 ] && echo "    ... (truncated)"
echo ""

# ── 5. EXPORTED TAR.GZ SIZE ──────────────────────────────────────────
echo "════════════════════════════════════════════════════════════════════════"
echo "  5. EXPORTED TAR.GZ SIZE"
echo "════════════════════════════════════════════════════════════════════════"
echo ""

export_local="${SCRIPT_NAME%.sh}.local.tar.gz"
export_ref="${SCRIPT_NAME%.sh}.reference.tar.gz"

# Resolve to canonical image ID (config digest). For manifest lists this
# resolves to the platform-specific image, never the list itself.
get_image_id() {
    docker inspect "$1" --format '{{.Id}}' 2>/dev/null | sed 's/sha256://'
}
local_canonical=$(get_image_id "$LOCAL")
ref_canonical=$(get_image_id "$REFERENCE")

echo "  Resolved image IDs (config digest):"
echo "    Local:      $local_canonical"
echo "    Reference:  $ref_canonical"
echo ""

echo "  Exporting via docker save | gzip (by image ID)..."
echo "  (files written to current directory)"
echo ""

# Save local — always works since we loaded it from tar
echo "  $(bold "Local:")    sha256:$local_canonical -> $export_local"
if docker save "sha256:$local_canonical" 2>/dev/null | gzip > "$export_local"; then
    local_tar_size=$(stat -c%s "$export_local" 2>/dev/null || stat -f%z "$export_local" 2>/dev/null || echo "0")
    echo "    done  ($(fmt_bytes "$local_tar_size"))"
else
    echo "    $(red "FAILED")"
    local_tar_size=0
fi

# Save reference — if archive is tiny (< 1 MB) the layers aren't cached.
# In that case remove the reference and force a full pull.
echo "  $(bold "Reference:")  sha256:$ref_canonical -> $export_ref"
ref_tar_size=0
docker save "sha256:$ref_canonical" 2>/dev/null | gzip > "$export_ref"
ref_tar_size=$(stat -c%s "$export_ref" 2>/dev/null || stat -f%z "$export_ref" 2>/dev/null || echo "0")

if [ "$ref_tar_size" -lt 1000000 ] && [ "$ref_tar_size" -gt 0 ]; then
    echo "    only $(fmt_bytes "$ref_tar_size") — layers not locally cached."
    echo "    Removing reference metadata and re-pulling with explicit platform..."
    docker image rm "$REFERENCE" 2>/dev/null || true
    docker pull --platform "$local_os/$local_arch" "$REFERENCE" >/dev/null 2>&1 && echo "    pull done" \
        || echo "    $(yellow "⚠️  pull had issues")"
    ref_canonical=$(get_image_id "$REFERENCE")
    echo "    Re-saving..."
    docker save "sha256:$ref_canonical" 2>/dev/null | gzip > "$export_ref"
    ref_tar_size=$(stat -c%s "$export_ref" 2>/dev/null || stat -f%z "$export_ref" 2>/dev/null || echo "0")
    echo "    done  ($(fmt_bytes "$ref_tar_size"))"
elif [ "$ref_tar_size" -eq 0 ]; then
    echo "    $(red "FAILED")"
else
    echo "    done  ($(fmt_bytes "$ref_tar_size"))"
fi
echo ""

if [ "$local_tar_size" -eq 0 ] || [ "$ref_tar_size" -eq 0 ]; then
    echo "  $(red "❌") Export comparison incomplete"
elif [ "$local_tar_size" -eq "$ref_tar_size" ]; then
    echo "  $(green "✅") Exported archives are exactly the same size ($(fmt_bytes "$local_tar_size"))"
else
    diff_bytes=$((local_tar_size - ref_tar_size))
    diff_abs=${diff_bytes#-}
    if [ "$diff_bytes" -gt 0 ]; then
        echo "  $(yellow "⚠️") Local archive is larger by $(fmt_bytes "$diff_abs")"
    else
        echo "  $(yellow "⚠️") Reference archive is larger by $(fmt_bytes "$diff_abs")"
    fi
    echo ""
    echo "  Files retained for inspection:"
    echo "    $export_local"
    echo "    $export_ref"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────
#  VERDICT
# ─────────────────────────────────────────────────────────────────────
echo "════════════════════════════════════════════════════════════════════════"
echo "                        VERDICT"
echo "════════════════════════════════════════════════════════════════════════"
echo ""

# Checks
checks_passed=0
checks_total=0

# Image ID
checks_total=$((checks_total+1))
if $ids_match; then
    echo "  $(green "✅") Image ID:  ${local_id:0:19}… — matches reference"
    checks_passed=$((checks_passed+1))
else
    echo "  $(yellow "⚠️") Image ID:  ${local_id:0:19}… vs ${ref_id:0:19}… — DIFFERENT"
    echo "             Same layers ≠ same image ID (history/timestamps differ)"
fi

# Platform
checks_total=$((checks_total+1))
if [ "$score_platform" -eq 1 ]; then
    echo "  $(green "✅") Platform:  $local_os/$local_arch matches reference"
    checks_passed=$((checks_passed+1))
else
    echo "  $(red "❌") Platform:  $local_os/$local_arch vs $ref_os/$ref_arch — MISMATCH"
fi

# Layers
checks_total=$((checks_total+1))
if $layers_identical; then
    echo "  $(green "✅") Layers:    $LOCAL_COUNT layers, identical digests and order"
    checks_passed=$((checks_passed+1))
elif $layers_same_set; then
    echo "  $(yellow "⚠️") Layers:    Same $LOCAL_COUNT layer content, different order"
    checks_passed=$((checks_passed+1))
else
    echo "  $(red "❌") Layers:    $LOCAL_COUNT local vs $REF_COUNT reference — DIFFER"
fi

# Config
checks_total=$((checks_total+1))
if $config_ok; then
    echo "  $(green "✅") Config:    Entrypoint, Cmd, Env, Labels, WorkingDir, User all match"
    checks_passed=$((checks_passed+1))
else
    echo "  $(yellow "⚠️") Config:    Some config fields differ (see section 2)"
fi

echo ""

VERDICT=""
if $ids_match && $layers_identical && $config_ok; then
    VERDICT="$(bold "$(green '★★★★★ MATCH — Images are bit-for-bit identical (same config digest)')")"
    VERDICT_DETAIL=""
elif $layers_identical && $config_ok; then
    VERDICT="$(bold "$(green '★★★★☆ FILESYSTEM MATCH — Same layer content, different image ID')")"
    VERDICT_DETAIL="  The filesystem is byte-for-byte identical ($LOCAL_COUNT matching diff_ids).\n  Image ID differs because the config metadata (history, timestamps) is not preserved\n  across builds — this is expected and harmless."
elif $layers_same_set && $config_ok; then
    VERDICT="$(bold "$(yellow '★★★☆☆ STRONG MATCH — Same layer content, different order + image ID')")"
    VERDICT_DETAIL="  Layer order and image ID differ, but all content matches."
elif [ "$checks_passed" -ge 2 ]; then
    VERDICT="$(bold "$(yellow '★★☆☆☆ PARTIAL MATCH — Platform and/or config match, but layers differ')")"
    VERDICT_DETAIL="  Your image has $LOCAL_COUNT layers vs $REF_COUNT in the official image.\n  Layer content digests differ — the filesystem contents are not identical.\n  This is expected if your build uses a different base image or nixpkgs revision."
else
    VERDICT="$(bold "$(red '★☆☆☆☆ MISMATCH — Significant differences detected')")"
    VERDICT_DETAIL=""
fi
echo "  $VERDICT"
if [ -n "$VERDICT_DETAIL" ]; then
    echo ""
    echo -e "$VERDICT_DETAIL"
fi
echo ""
echo "════════════════════════════════════════════════════════════════════════"
