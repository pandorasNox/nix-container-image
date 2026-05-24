#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

usage() {
    cat <<EOF
Download and adapt two container images for skopeo inspection.

Usage: $SCRIPT_NAME <local-tar-gz> <reference-image>

Arguments:
  local-tar-gz     Path to the gzipped Docker image tarball from nix build
                   (e.g., ./result or ./image.tar.gz).
  reference-image  Registry reference, with or without docker://
                   (e.g., nixos/nix@sha256:bf1d... or docker://nixos/nix:2.34.7)

Requires: skopeo
EOF
    exit 1
}

LOCAL_GZ="${1:-}"
REFERENCE="${2:-}"
[ -z "$LOCAL_GZ" ] || [ -z "$REFERENCE" ] && usage

for cmd in skopeo; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: '$cmd' is required but not found." >&2
        exit 1
    fi
done

# Normalise reference
if [[ "$REFERENCE" != *"://"* ]]; then
    REFERENCE="docker://$REFERENCE"
fi

# ── paths ──────────────────────────────────────────────────────────────
WORKDIR="$(pwd)/compare"
mkdir -p "$WORKDIR"
LOCAL_TAR="${WORKDIR}/local-image.tar"
LOCAL_OCI="${WORKDIR}/local-oci"
REF_OCI="${WORKDIR}/reference-oci"
LOG="${WORKDIR}/result.compare.log"

# Tee all output to log
exec > >(tee -a "$LOG") 2>&1

cleanup() {
    echo ""
    echo "Cleaning up..."
    [ -f "$LOCAL_TAR" ] && rm -f "$LOCAL_TAR"
    [ -d "$LOCAL_OCI" ] && rm -rf "$LOCAL_OCI"
    [ -d "$REF_OCI" ]   && rm -rf "$REF_OCI"
}
trap cleanup EXIT

# ── 1. Adapt local image ──────────────────────────────────────────────
echo "  [1/3] Uncompressing local image: $LOCAL_GZ → $(basename "$LOCAL_TAR")"
if [[ "$LOCAL_GZ" == *.gz ]]; then
    gunzip -c "$LOCAL_GZ" > "$LOCAL_TAR"
else
    cp "$LOCAL_GZ" "$LOCAL_TAR"
fi
echo "    done  ($(stat -c%s "$LOCAL_TAR" 2>/dev/null || stat -f%z "$LOCAL_TAR") bytes)"
echo ""

echo "  [2/3] Converting local image to OCI layout..."
skopeo copy "docker-archive:$LOCAL_TAR" "oci:$LOCAL_OCI:latest" --quiet
echo "    done  → $LOCAL_OCI"
echo ""

# ── 2. Download reference image ───────────────────────────────────────
echo "  [3/3] Downloading reference image to OCI layout..."
echo "        Source: $REFERENCE"
skopeo copy --multi-arch=all "$REFERENCE" "oci:$REF_OCI:latest" --quiet
echo "    done  → $REF_OCI"
echo ""

# ── 3. Inspect both ───────────────────────────────────────────────────
echo "════════════════════════════════════════════════════════════════════════"
echo "  Images ready for inspection"
echo "════════════════════════════════════════════════════════════════════════"
echo ""
echo "  Work dir:   $WORKDIR"
echo "  Log:        $LOG"
echo ""
echo "  Local OCI:      $LOCAL_OCI"
echo "  Reference OCI:  $REF_OCI"
echo ""
echo "  Inspect with:"
echo "    skopeo inspect oci:$LOCAL_OCI:latest"
echo "    skopeo inspect oci:$REF_OCI:latest"
echo ""
echo "  Raw manifest:"
echo "    skopeo inspect --raw oci:$LOCAL_OCI:latest"
echo "    skopeo inspect --raw oci:$REF_OCI:latest"
echo ""
echo "  Compare layers:"
echo "    diff <(skopeo inspect --raw oci:$LOCAL_OCI:latest | jq -r '.layers[].digest') \\"
echo "         <(skopeo inspect --raw oci:$REF_OCI:latest | jq -r '.layers[].digest')"
echo ""
echo "  Config diff (skip timestamps):"
echo "    jq 'del(.history, .created)' \\"
echo "      <(skopeo inspect oci:$LOCAL_OCI:latest) \\"
echo "      > /tmp/local-config.json"
echo "    jq 'del(.history, .created)' \\"
echo "      <(skopeo inspect oci:$REF_OCI:latest) \\"
echo "      > /tmp/ref-config.json"
echo "    diff /tmp/local-config.json /tmp/ref-config.json"
echo ""

# Keep OCI directories
trap - EXIT
cleanup() {
    [ -f "$LOCAL_TAR" ] && rm -f "$LOCAL_TAR"
}
trap cleanup EXIT

echo "  OCI directories preserved for further inspection."
echo "    $LOCAL_OCI"
echo "    $REF_OCI"
echo "    $(basename "$LOCAL_TAR") cleaned up automatically."
echo ""
echo "  Log written to: $LOG"

# ════════════════════════════════════════════════════════════════════
#  COMPARISON
# ════════════════════════════════════════════════════════════════════

die() { echo "Error: $*" >&2; exit 1; }
bold() { printf '\e[1m%s\e[0m' "$1"; }
green() { printf '\e[32m%s\e[0m' "$1"; }
yellow() { printf '\e[33m%s\e[0m' "$1"; }
red() { printf '\e[31m%s\e[0m' "$1"; }

fmt_bytes() {
    local b=$1
    if command -v numfmt &>/dev/null; then
        numfmt --to=iec <<<"$b"
    else
        echo "$((b / 1024 / 1024)) MiB"
    fi
}

echo ""
echo "════════════════════════════════════════════════════════════════════════"
echo "                     IMAGE COMPARISON REPORT (skopeo)"
echo "════════════════════════════════════════════════════════════════════════"
echo ""

# ── fetch raw manifests (always --raw) ────────────────────────────
echo "  Fetching raw manifests..."
loc_manifest=$(skopeo inspect --raw "oci:$LOCAL_OCI:latest" 2>/dev/null || die "Cannot get raw manifest for local")
ref_index=$(skopeo inspect --raw "oci:$REF_OCI:latest" 2>/dev/null || die "Cannot get raw manifest for reference")
echo "    done"
echo ""

# ── determine manifest types ─────────────────────────────────────
loc_mt=$(jq -r '.mediaType // ""' <<<"$loc_manifest")
loc_is_index=false
echo "$loc_mt" | grep -qiE '(image.index|manifest.list)' && loc_is_index=true

ref_mt=$(jq -r '.mediaType // ""' <<<"$ref_index")
ref_is_index=false
echo "$ref_mt" | grep -qiE '(image.index|manifest.list)' && ref_is_index=true

# ── helper: read a blob from OCI layout on disk ──────────────────
read_oci_blob() {
    local oci_dir="$1" digest="$2"
    local algo="${digest%%:*}"
    local hash="${digest#*:}"
    cat "$oci_dir/blobs/$algo/$hash" 2>/dev/null || echo ""
}

# ── read config blobs directly from disk ─────────────────────────
echo "  Reading config blobs from OCI layout..."
loc_config_digest=$(jq -r '.config.digest // ""' <<<"$loc_manifest")
loc_config=$(read_oci_blob "$LOCAL_OCI" "$loc_config_digest")
[ -n "$loc_config" ] || die "Cannot read config blob $loc_config_digest from $LOCAL_OCI"

if $ref_is_index; then
    echo "    Reference is an image index — resolving to arm64 manifest..."
    ref_entry=$(jq -r ".manifests[] | select(.platform.architecture == \"arm64\" and .platform.os == \"linux\") | .digest" <<<"$ref_index" 2>/dev/null || echo "")
    if [ -z "$ref_entry" ]; then
        ref_entry=$(jq -r '.manifests[0].digest' <<<"$ref_index")
        echo "      (no explicit arm64 entry, using first: $ref_entry)"
    else
        echo "      arm64 digest: $ref_entry"
    fi
    ref_manifest=$(read_oci_blob "$REF_OCI" "$ref_entry")
    [ -n "$ref_manifest" ] || die "Cannot read manifest blob $ref_entry from $REF_OCI"
    ref_config_digest=$(jq -r '.config.digest // ""' <<<"$ref_manifest")
    ref_config=$(read_oci_blob "$REF_OCI" "$ref_config_digest")
    [ -n "$ref_config" ] || die "Cannot read config blob $ref_config_digest from $REF_OCI"
else
    ref_manifest="$ref_index"
    ref_config_digest=$(jq -r '.config.digest // ""' <<<"$ref_manifest")
    ref_config=$(read_oci_blob "$REF_OCI" "$ref_config_digest")
    [ -n "$ref_config" ] || die "Cannot read config blob $ref_config_digest from $REF_OCI"
fi
echo "    done"
echo ""

# ── config digest (image ID) ─────────────────────────────────────
loc_id="$loc_config_digest"
ref_id="$ref_config_digest"
ids_match=false
[ "$loc_id" = "$ref_id" ] && ids_match=true

# ── platform ─────────────────────────────────────────────────────
loc_os=$(jq -r '.architecture // ""'  <<<"$loc_config")
loc_arch=$(jq -r '.architecture // ""' <<<"$loc_config")
loc_variant=$(jq -r '.variant // ""'   <<<"$loc_config")
loc_created=$(jq -r '.created // ""'   <<<"$loc_config" | cut -d. -f1 | tr T ' ')

ref_os=$(jq -r '.architecture // ""'  <<<"$ref_config")
ref_arch=$(jq -r '.architecture // ""' <<<"$ref_config")
ref_variant=$(jq -r '.variant // ""'   <<<"$ref_config")
ref_created=$(jq -r '.created // ""'   <<<"$ref_config" | cut -d. -f1 | tr T ' ')

# ── manifest platforms (index info) ──────────────────────────────
ref_index_platforms=""
if $ref_is_index; then
    ref_index_platforms=$(jq -r '.manifests[] | "    - \(.platform.os)/\(.platform.architecture)\(.platform.variant // "")"' <<<"$ref_index")
fi
loc_manifest_platform="    - $loc_os/$loc_arch${loc_variant:+$loc_variant}"

# ── layers: content diff_ids (from config) ───────────────────────
loc_diff_ids=$(jq -r '.rootfs.diff_ids[]' <<<"$loc_config" 2>/dev/null || echo "")
ref_diff_ids=$(jq -r '.rootfs.diff_ids[]' <<<"$ref_config" 2>/dev/null || echo "")

mapfile -t LOC_DIFF < <(echo "$loc_diff_ids")
mapfile -t REF_DIFF < <(echo "$ref_diff_ids")

LOC_DIFF_COUNT="${#LOC_DIFF[@]}"
REF_DIFF_COUNT="${#REF_DIFF[@]}"

diff_ids_identical=false
diff_ids_same_set=false
if [ "$LOC_DIFF_COUNT" -eq "$REF_DIFF_COUNT" ]; then
    if [ "${LOC_DIFF[*]}" = "${REF_DIFF[*]}" ]; then
        diff_ids_identical=true
    else
        IFS=$'\n' LOC_DIFF_SORTED=($(sort <<<"${LOC_DIFF[*]}"))
        IFS=$'\n' REF_DIFF_SORTED=($(sort   <<<"${REF_DIFF[*]}"))
        unset IFS
        [ "${LOC_DIFF_SORTED[*]}" = "${REF_DIFF_SORTED[*]}" ] && diff_ids_same_set=true
    fi
fi

# ── layers: compressed manifest layers (from manifest) ───────────
parse_layers() {
    local raw="$1"
    jq -r '.layers[] | "\(.digest) \(.size)"' <<<"$raw" 2>/dev/null || echo ""
}

loc_mlayer_str=$(parse_layers "$loc_manifest")
ref_mlayer_str=$(parse_layers "$ref_manifest")

mapfile -t LOC_MLAYERS < <(echo "$loc_mlayer_str" | awk '{print $1}')
mapfile -t LOC_MSIZES  < <(echo "$loc_mlayer_str" | awk '{print $2}')
mapfile -t REF_MLAYERS < <(echo "$ref_mlayer_str"  | awk '{print $1}')
mapfile -t REF_MSIZES  < <(echo "$ref_mlayer_str"  | awk '{print $2}')

LOC_MCOUNT="${#LOC_MLAYERS[@]}"
REF_MCOUNT="${#REF_MLAYERS[@]}"
LOC_MTOTAL=$(echo "${LOC_MSIZES[@]:-0}" | tr ' ' '+' | bc 2>/dev/null || echo "0")
REF_MTOTAL=$(echo "${REF_MSIZES[@]:-0}" | tr ' ' '+' | bc 2>/dev/null || echo "0")

IFS=$'\n' LOC_MSORTED=($(sort <<<"${LOC_MLAYERS[*]}"))
IFS=$'\n' REF_MSORTED=($(sort   <<<"${REF_MLAYERS[*]}"))
unset IFS

manifest_layers_identical=false
manifest_layers_same_set=false
if [ "$LOC_MCOUNT" -eq "$REF_MCOUNT" ] && [ "${LOC_MLAYERS[*]}" = "${REF_MLAYERS[*]}" ]; then
    manifest_layers_identical=true
elif [ "$LOC_MCOUNT" -eq "$REF_MCOUNT" ] && [ "${LOC_MSORTED[*]}" = "${REF_MSORTED[*]}" ]; then
    manifest_layers_same_set=true
fi

# ── config: runtime fields (Entrypoint, Cmd, Env, Labels, ...) ───
loc_runtime=$(jq -r '.config' <<<"$loc_config")
ref_runtime=$(jq -r '.config' <<<"$ref_config")

config_field_eq() {
    local key="$1"
    local lc rc
    lc=$(jq -r "${key}" <<<"$loc_runtime" 2>/dev/null || echo "__NULL__")
    rc=$(jq -r "${key}" <<<"$ref_runtime" 2>/dev/null || echo "__NULL__")
    [ "${lc:-null}" = "${rc:-null}" ] || { [ "$lc" = "null" ] && [ "$rc" = "__NULL__" ]; } || { [ "$lc" = "__NULL__" ] && [ "$rc" = "null" ]; }
}

config_ok=true
for key in '.Entrypoint' '.Cmd' '.User' '.WorkingDir'; do
    config_field_eq "$key" || { config_ok=false; break; }
done

loc_env_str=$(jq -r '.Env // [] | sort[]' <<<"$loc_runtime" 2>/dev/null)
ref_env_str=$(jq -r '.Env // [] | sort[]' <<<"$ref_runtime" 2>/dev/null)
[ "$loc_env_str" != "$ref_env_str" ] && config_ok=false

loc_label_str=$(jq -r '.Labels // {} | to_entries | sort_by(.key) | .[] | "\(.key)=\(.value)"' <<<"$loc_runtime" 2>/dev/null)
ref_label_str=$(jq -r '.Labels // {} | to_entries | sort_by(.key) | .[] | "\(.key)=\(.value)"' <<<"$ref_runtime" 2>/dev/null)
[ "$loc_label_str" != "$ref_label_str" ] && config_ok=false

# ── OCI export for size comparison ─────────────────────────────────
export_ok=false
export_local_oci="${WORKDIR}/local-oci.tar.gz"
export_ref_oci="${WORKDIR}/reference-oci.tar.gz"

if command -v tar &>/dev/null; then
    echo "  Creating compressed OCI archives for size comparison..."
    tar czf "$export_local_oci" -C "$WORKDIR" local-oci 2>/dev/null
    tar czf "$export_ref_oci"  -C "$WORKDIR" reference-oci 2>/dev/null
    export_ok=true
    echo "    done"
    echo ""
fi

# ════════════════════════════════════════════════════════════════════
#  REPORT
# ════════════════════════════════════════════════════════════════════

echo ""
echo "════════════════════════════════════════════════════════════════════════"
echo "                     IMAGE COMPARISON REPORT (skopeo)"
echo "════════════════════════════════════════════════════════════════════════"
echo ""
echo "  $(bold "Local:")      $(basename "$LOCAL_GZ")"
echo "  $(bold "Reference:")  $REFERENCE"
echo ""

# ── 1. PLATFORM & MANIFEST ──────────────────────────────────────────
echo "════════════════════════════════════════════════════════════════════════"
echo "  1. PLATFORM & MANIFEST"
echo "════════════════════════════════════════════════════════════════════════"
printf "  %-20s  %-22s  %s\n" "Property" "Local" "Reference"
printf "  %-20s  %-22s  %s\n" "────────"  "─────"  "─────────"
printf "  %-20s  %-22s  %s\n" "Architecture" "$loc_arch" "$ref_arch"
printf "  %-20s  %-22s  %s\n" "OS" "$loc_os" "$ref_os"
printf "  %-20s  %-22s  %s\n" "Variant" "${loc_variant:-<none>}" "${ref_variant:-<none>}"
echo ""

echo "  $(bold "Manifest type:")"
echo "    Local:      $($loc_is_index && echo "image index (multi-arch)" || echo "single image manifest")"
echo "    Reference:  $($ref_is_index && echo "image index (multi-arch)" || echo "single image manifest")"
echo ""

echo "  $(bold "Available architectures:")"
echo "    Local:"
echo "$loc_manifest_platform"
echo "    Reference:"
if $ref_is_index; then
    echo "$ref_index_platforms"
else
    echo "    - $ref_os/$ref_arch${ref_variant:+ $ref_variant}"
fi
echo ""

if $ref_is_index; then
    if echo "$ref_index_platforms" | grep -qi "${loc_os}/${loc_arch}"; then
        echo "  $(green "✅") Local arch $loc_os/$loc_arch $(bold "IS") listed in reference index"
    else
        echo "  $(red "❌") Local arch $loc_os/$loc_arch is $(bold "NOT") listed in reference index"
    fi
    echo ""
fi

# ── 2. IMAGE CONFIG ─────────────────────────────────────────────────
echo "════════════════════════════════════════════════════════════════════════"
echo "  2. IMAGE CONFIG"
echo "════════════════════════════════════════════════════════════════════════"
printf "  %-20s  %-22s  %s\n" "Property" "Local" "Reference"
printf "  %-20s  %-22s  %s\n" "────────"  "─────"  "─────────"
printf "  %-20s  %-22s  %s\n" "Config Digest" "${loc_id:0:19}..." "${ref_id:0:19}..."
printf "  %-20s  %-22s  %s\n" "Created" "${loc_created:-<none>}" "${ref_created:-<none>}"
echo ""
if $ids_match; then
    echo "  $(green "✅") Config digests match — identical config blob"
else
    echo "  $(yellow "⚠️  Config digests differ — config metadata differs")"
fi
echo ""

# Entrypoint
loc_ep=$(jq -r '.Entrypoint // [] | join(" ")' <<<"$loc_runtime" 2>/dev/null)
ref_ep=$(jq -r '.Entrypoint // [] | join(" ")' <<<"$ref_runtime" 2>/dev/null)
[ -z "$loc_ep" ] && loc_ep="<none>"
[ -z "$ref_ep" ] && ref_ep="<none>"
echo "  $(bold "Entrypoint:")"
echo "    Local:      $loc_ep"
echo "    Reference:  $ref_ep"
echo ""

# Cmd
loc_cmd=$(jq -r '.Cmd // [] | join(" ")' <<<"$loc_runtime" 2>/dev/null)
ref_cmd=$(jq -r '.Cmd // [] | join(" ")' <<<"$ref_runtime" 2>/dev/null)
[ -z "$loc_cmd" ] && loc_cmd="<none>"
[ -z "$ref_cmd" ] && ref_cmd="<none>"
echo "  $(bold "Cmd:")"
echo "    Local:      $loc_cmd"
echo "    Reference:  $ref_cmd"
echo ""

# WorkingDir
loc_wd=$(jq -r '.WorkingDir // ""' <<<"$loc_runtime")
ref_wd=$(jq -r '.WorkingDir // ""' <<<"$ref_runtime")
[ -z "$loc_wd" ] && loc_wd="<none>"
[ -z "$ref_wd" ] && ref_wd="<none>"
echo "  $(bold "WorkingDir:")  $loc_wd  |  $ref_wd"
echo ""

# User
loc_user=$(jq -r '.User // ""' <<<"$loc_runtime")
ref_user=$(jq -r '.User // ""' <<<"$ref_runtime")
[ -z "$loc_user" ] && loc_user="<none>"
[ -z "$ref_user" ] && ref_user="<none>"
echo "  $(bold "User:")  $loc_user  |  $ref_user"
echo ""

# Environment
echo "  $(bold "Environment (sorted):")"
loc_env=$(jq -r '.Env // [] | sort[]' <<<"$loc_runtime" 2>/dev/null || echo "<none>")
ref_env=$(jq -r '.Env // [] | sort[]' <<<"$ref_runtime" 2>/dev/null || echo "<none>")
if [ "$loc_env" = "$ref_env" ]; then
    echo "    ✅ Identical"
    echo "$loc_env" | while IFS= read -r line; do [ -n "$line" ] && echo "       $line"; done
else
    echo "    ⚠️  Differ:"
    diff -u0 <(echo "$loc_env") <(echo "$ref_env") 2>/dev/null | tail -n+3 || true
fi
echo ""

# Labels
echo "  $(bold "Labels (sorted):")"
loc_labels=$(jq -r '.Labels // {} | to_entries | sort_by(.key) | .[] | "\(.key)=\(.value)"' <<<"$loc_runtime" 2>/dev/null)
ref_labels=$(jq -r '.Labels // {} | to_entries | sort_by(.key) | .[] | "\(.key)=\(.value)"' <<<"$ref_runtime" 2>/dev/null)
[ -z "$loc_labels" ] && loc_labels="<none>"
[ -z "$ref_labels" ] && ref_labels="<none>"
if [ "$loc_labels" = "$ref_labels" ]; then
    echo "    ✅ Identical"
    [ "$loc_labels" != "<none>" ] && echo "$loc_labels" | while IFS= read -r line; do echo "       $line"; done
else
    echo "    ⚠️  Differ:"
    diff -u0 <(echo "$loc_labels") <(echo "$ref_labels") 2>/dev/null | tail -n+3 || true
fi
echo ""

# ── 3. LAYERS ───────────────────────────────────────────────────────
echo "════════════════════════════════════════════════════════════════════════"
echo "  3. LAYERS"
echo "════════════════════════════════════════════════════════════════════════"
echo ""

# ── section 3a: content diff_ids (from config .rootfs.diff_ids) ──
echo "  $(bold "Content layers (diff_ids — $LOC_DIFF_COUNT local, $REF_DIFF_COUNT reference):")"
if $diff_ids_identical; then
    echo "    ✅ $(green "IDENTICAL") — same digests, same order"
    for ((i=0; i<LOC_DIFF_COUNT; i++)); do
        echo "    ${LOC_DIFF[$i]}"
    done
elif $diff_ids_same_set; then
    echo "    ⚠️  Same digests, different order"
    for ((i=0; i<LOC_DIFF_COUNT; i++)); do
        echo "    ${LOC_DIFF[$i]}"
    done
elif [ "$LOC_DIFF_COUNT" -eq 0 ] || [ "$REF_DIFF_COUNT" -eq 0 ]; then
    echo "    $(yellow "⚠️  Could not extract diff_ids from configs")"
else
    echo "    $(red "❌ DIFFER") — $LOC_DIFF_COUNT local vs $REF_DIFF_COUNT reference"
    IFS=$'\n' loc_ds=($(sort <<<"${LOC_DIFF[*]}"))
    IFS=$'\n' ref_ds=($(sort   <<<"${REF_DIFF[*]}"))
    unset IFS
    only_l=$(comm -23 <(printf '%s\n' "${loc_ds[@]}") <(printf '%s\n' "${ref_ds[@]}") || true)
    only_r=$(comm -13 <(printf '%s\n' "${loc_ds[@]}") <(printf '%s\n' "${ref_ds[@]}") || true)
    [ -n "$only_l" ] && echo "    Only local:" && echo "$only_l" | sed 's/^/      + /'
    [ -n "$only_r" ] && echo "    Only reference:" && echo "$only_r" | sed 's/^/      - /'
fi
echo ""

# ── section 3b: compressed manifest layers (from manifest) ────────
if [ "$LOC_MCOUNT" -gt 0 ] || [ "$REF_MCOUNT" -gt 0 ]; then
    echo "  $(bold "Compressed manifest layers ($LOC_MCOUNT local, $REF_MCOUNT reference):")"
    if [ "$LOC_MCOUNT" -gt 0 ]; then
        echo "    Local ($(fmt_bytes "$LOC_MTOTAL")):"
        for ((i=0; i<LOC_MCOUNT; i++)); do
            printf "      %-71s  %s\n" "${LOC_MLAYERS[$i]}" "$(fmt_bytes "${LOC_MSIZES[$i]}")"
        done
    fi
    if [ "$REF_MCOUNT" -gt 0 ]; then
        echo "    Reference ($(fmt_bytes "$REF_MTOTAL")):"
        for ((i=0; i<REF_MCOUNT; i++)); do
            printf "      %-71s  %s\n" "${REF_MLAYERS[$i]}" "$(fmt_bytes "${REF_MSIZES[$i]}")"
        done
    fi
    echo ""

    if $manifest_layers_identical; then
        echo "    $(green "✅") Manifest layers IDENTICAL (same digests, same order)"
        [ "$LOC_MTOTAL" -eq "$REF_MTOTAL" ] && [ "$LOC_MTOTAL" -gt 0 ] && \
            echo "    $(green "✅") Compressed sizes also match"
    elif $manifest_layers_same_set; then
        echo "    $(yellow "⚠️  Same manifest layers, different order")"
    elif [ "$LOC_MCOUNT" -gt 0 ] && [ "$REF_MCOUNT" -gt 0 ]; then
        echo "    $(red "❌") Manifest layers differ"
        only_lm=$(comm -23 <(printf '%s\n' "${LOC_MSORTED[@]}") <(printf '%s\n' "${REF_MSORTED[@]}") || true)
        only_rm=$(comm -13 <(printf '%s\n' "${LOC_MSORTED[@]}") <(printf '%s\n' "${REF_MSORTED[@]}") || true)
        [ -n "$only_lm" ] && echo "      Only local:" && echo "$only_lm" | sed 's/^/        + /'
        [ -n "$only_rm" ] && echo "      Only reference:" && echo "$only_rm" | sed 's/^/        - /'
    fi
fi
echo ""

# ── 4. EXPORTED SIZE (OCI archives) ────────────────────────────────
echo "════════════════════════════════════════════════════════════════════════"
echo "  4. EXPORTED SIZE (OCI tar.gz)"
echo "════════════════════════════════════════════════════════════════════════"
echo ""

export_comparable=false
if $export_ok; then
    local_tar_sz=$(stat -c%s "$export_local_oci" 2>/dev/null || stat -f%z "$export_local_oci" 2>/dev/null || echo "0")
    ref_tar_sz=$(stat -c%s "$export_ref_oci" 2>/dev/null || stat -f%z "$export_ref_oci" 2>/dev/null || echo "0")
    if [ "$local_tar_sz" -gt 0 ] && [ "$ref_tar_sz" -gt 0 ]; then
        export_comparable=true
        printf "  %-35s  %s\n" "Archive" "Size"
        printf "  %-35s  %s\n" "───────" "────"
        printf "  %-35s  %s\n" "$(basename "$export_local_oci")" "$(fmt_bytes "$local_tar_sz")"
        printf "  %-35s  %s\n" "$(basename "$export_ref_oci")"   "$(fmt_bytes "$ref_tar_sz")"
        echo ""
        if [ "$local_tar_sz" -eq "$ref_tar_sz" ]; then
            echo "  $(green "✅") Archives are the same size"
        else
            diff_bytes=$((local_tar_sz - ref_tar_sz))
            diff_abs=${diff_bytes#-}
            if [ "$diff_bytes" -gt 0 ]; then
                echo "  $(yellow "⚠️") Local archive is larger by $(fmt_bytes "$diff_abs")"
            else
                echo "  $(yellow "⚠️") Reference archive is larger by $(fmt_bytes "$diff_abs")"
            fi
        fi
    fi
fi
if ! $export_comparable; then
    echo "  Export comparison not available."
    if [ "$LOC_MTOTAL" -gt 0 ]; then
        echo "  Layer compressed sizes from manifest:"
        echo "    Local:      $(fmt_bytes "$LOC_MTOTAL")"
        echo "    Reference:  $(fmt_bytes "$REF_MTOTAL")"
    fi
fi
echo ""

# ─────────────────────────────────────────────────────────────────────
#  VERDICT
# ─────────────────────────────────────────────────────────────────────
echo "════════════════════════════════════════════════════════════════════════"
echo "                        VERDICT"
echo "════════════════════════════════════════════════════════════════════════"
echo ""

checks_passed=0
checks_total=0

# Config digest (image ID)
checks_total=$((checks_total+1))
if $ids_match; then
    echo "  $(green "✅") Config:     ${loc_id:0:19}… — matches reference"
    checks_passed=$((checks_passed+1))
else
    echo "  $(yellow "⚠️") Config:     ${loc_id:0:19}… vs ${ref_id:0:19}… — DIFFERENT"
fi

# Platform
checks_total=$((checks_total+1))
if [ "$loc_os" = "$ref_os" ] && [ "$loc_arch" = "$ref_arch" ]; then
    echo "  $(green "✅") Platform:   $loc_os/$loc_arch matches reference"
    checks_passed=$((checks_passed+1))
else
    echo "  $(red "❌") Platform:   $loc_os/$loc_arch vs $ref_os/$ref_arch — MISMATCH"
fi

# Layers (diff_ids)
checks_total=$((checks_total+1))
if $diff_ids_identical; then
    echo "  $(green "✅") Layers:     $LOC_DIFF_COUNT layers, identical diff_ids and order"
    checks_passed=$((checks_passed+1))
elif $diff_ids_same_set; then
    echo "  $(yellow "⚠️") Layers:     Same $LOC_DIFF_COUNT layer diff_ids, different order"
    checks_passed=$((checks_passed+1))
else
    echo "  $(red "❌") Layers:     $LOC_DIFF_COUNT local vs $REF_DIFF_COUNT reference — DIFFER"
fi

# Runtime config
checks_total=$((checks_total+1))
if $config_ok; then
    echo "  $(green "✅") Runtime:    Entrypoint, Cmd, Env, Labels, WorkingDir, User all match"
    checks_passed=$((checks_passed+1))
else
    echo "  $(yellow "⚠️") Runtime:    Some runtime config fields differ (see section 2)"
fi

echo ""

if $ids_match && $diff_ids_identical && $config_ok; then
    echo "  $(bold "$(green '★★★★★ MATCH — Images are bit-for-bit identical (same config digest)')")"
elif $diff_ids_identical && $config_ok; then
    echo "  $(bold "$(green '★★★★☆ FILESYSTEM MATCH — Same layer content, different config digest')")"
    echo ""
    echo "  The filesystem is byte-for-byte identical ($LOC_DIFF_COUNT matching diff_ids)."
    echo "  Digest differs because config metadata (history, timestamps) is not preserved"
    echo "  across builds — this is expected and harmless."
elif $diff_ids_same_set && $config_ok; then
    echo "  $(bold "$(yellow '★★★☆☆ STRONG MATCH — Same layer content, different order')")"
elif [ "$checks_passed" -ge 2 ]; then
    echo "  $(bold "$(yellow '★★☆☆☆ PARTIAL MATCH — Platform and/or runtime config match, but layers differ')")"
    echo ""
    echo "  Your image has $LOC_DIFF_COUNT layers vs $REF_DIFF_COUNT in the official image."
    echo "  Layer diff_ids differ — the filesystem contents are not identical."
else
    echo "  $(bold "$(red '★☆☆☆☆ MISMATCH — Significant differences detected')")"
fi
echo ""
echo "════════════════════════════════════════════════════════════════════════"
echo ""

if $export_comparable; then
    echo "  Exported archives retained:"
    echo "    $export_local_oci"
    echo "    $export_ref_oci"
fi
echo "  Log written to: $LOG"
