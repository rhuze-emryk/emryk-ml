#!/usr/bin/env bash
# Compare the kernel and NVIDIA driver pinned in Containerfile with what
# Universal Blue currently ships, and print key=value lines for $GITHUB_OUTPUT.
#
# Renovate only refreshes digests within a tag. A new kernel arrives as a new
# akmods-nvidia-open *tag* (main-<fedora>-<kver>), which Renovate never sees,
# and upstream later deletes the old tag, which breaks our digest pin. This
# script surfaces both events.
#
# state is one of:
#   current  pins match upstream kernel + NVIDIA driver
#   waiting  base has a newer kernel but its akmods image is not published yet
#   ready    matching base + akmods exist upstream; a pin bump can ship now
#   broken   the pinned akmods digest is no longer fetchable (builds will fail)
#
# Usage: scripts/check-kernel-nvidia-upstream.sh [Containerfile]
set -euo pipefail

containerfile=${1:-Containerfile}
registry=ghcr.io
akmods_repo=ublue-os/akmods-nvidia-open
base_repo=ublue-os/kinoite-main

die() { echo "error: $*" >&2; exit 1; }

akmods_ref=$(grep -oP 'akmods-nvidia-open:\K[^[:space:]]+' "$containerfile") \
    || die "no akmods-nvidia-open FROM line in $containerfile"
pinned_tag=${akmods_ref%@*}
pinned_digest=${akmods_ref#*@}
pinned_kver=$(grep -oP '^main-[0-9]+-\K.+' <<<"$pinned_tag") \
    || die "unexpected akmods tag format: $pinned_tag"
major=$(grep -oP 'kinoite-main:\K[0-9]+(?=@)' "$containerfile") \
    || die "kinoite-main is not pinned to a numeric Fedora major"
pinned_base_digest=$(grep -oP 'kinoite-main:[0-9]+@\K\S+' "$containerfile")

token=$(curl -fsSL "https://${registry}/token?scope=repository:${akmods_repo}:pull" | jq -r .token)

# Print the image manifest for a tag or digest (amd64 entry if it is an index).
# Fails if the reference does not exist.
manifest() {
    local ref=$1 accept json
    accept='application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json,application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json'
    json=$(curl -fsSL -H "Authorization: Bearer $token" -H "Accept: $accept" \
        "https://${registry}/v2/${akmods_repo}/manifests/${ref}") || return 1
    if jq -e '.manifests' >/dev/null <<<"$json"; then
        ref=$(jq -r '.manifests[] | select(.platform.architecture == "amd64") | .digest' <<<"$json" | head -1)
        manifest "$ref"
    else
        printf '%s\n' "$json"
    fi
}

# NVIDIA_AKMOD_VERSION from rpms/kmods/nvidia-vars inside the akmods image.
# Upstream does not label it, so stream the layers until the file turns up.
nvidia_version() {
    local json layer version
    json=$(manifest "$1") || return 1
    for layer in $(jq -r '.layers[].digest' <<<"$json"); do
        version=$(curl -fsSL -H "Authorization: Bearer $token" \
            "https://${registry}/v2/${akmods_repo}/blobs/${layer}" \
            | tar -xzO rpms/kmods/nvidia-vars 2>/dev/null \
            | grep -oP '^NVIDIA_AKMOD_VERSION=\K\S+' || true)
        if [[ -n $version ]]; then
            echo "$version"
            return 0
        fi
    done
    return 1
}

tag_digest() {
    skopeo inspect --no-tags "docker://${registry}/${akmods_repo}:$1" 2>/dev/null | jq -r .Digest
}

base_json=$(skopeo inspect --no-tags "docker://${registry}/${base_repo}:${major}")
upstream_kver=$(jq -r '.Labels["ostree.linux"]' <<<"$base_json")
upstream_base_digest=$(jq -r .Digest <<<"$base_json")
[[ $upstream_kver == *fc${major}* ]] || die "unexpected kernel label on ${base_repo}:${major}: $upstream_kver"

target_tag="main-${major}-${upstream_kver}"
target_digest=$(tag_digest "$target_tag" || true)
pinned_nvidia=$(nvidia_version "$pinned_digest" || true)
target_nvidia=''
if [[ $target_digest == "$pinned_digest" ]]; then
    target_nvidia=$pinned_nvidia
elif [[ -n $target_digest ]]; then
    target_nvidia=$(nvidia_version "$target_digest" || true)
fi

if [[ -z $pinned_nvidia ]]; then
    state=broken
elif [[ -z $target_digest ]]; then
    state=waiting
elif [[ $upstream_kver != "$pinned_kver" || $target_nvidia != "$pinned_nvidia" ]]; then
    state=ready
else
    state=current
fi

cat <<EOF
state=$state
major=$major
pinned_tag=$pinned_tag
pinned_digest=$pinned_digest
pinned_kver=$pinned_kver
pinned_nvidia=${pinned_nvidia:-unknown}
pinned_base_digest=$pinned_base_digest
upstream_kver=$upstream_kver
upstream_base_digest=$upstream_base_digest
target_tag=$target_tag
target_digest=${target_digest:-none}
target_nvidia=${target_nvidia:-unknown}
EOF
