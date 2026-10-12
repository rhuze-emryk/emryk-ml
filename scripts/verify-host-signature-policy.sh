#!/usr/bin/env bash
# Pull an image the way an enforcing Emryk host does: Fedora's skopeo, the
# shipped containers-policy.json and registries.d, and our public key at the
# path the policy names. `cosign verify` alone is a proxy; hosts verify through
# containers/image, and the two can disagree (attachment format, policy shape,
# key path). If they ever do, hosts refuse every update while CI stays green.
#
# The policy is evaluated before any layer is fetched, so a rejection fails in
# seconds; an accepted image is copied in full to a throwaway directory.
#
# Usage: scripts/verify-host-signature-policy.sh <registry/repo@sha256:...>
# Env:   FEDORA_TOOLS_IMAGE  Fedora image providing skopeo (required)
#        PUBLIC_KEY          key to install as rhuze-emryk.pub (default cosign.pub)
set -euo pipefail

ref=${1:?usage: $0 <registry/repo@sha256:...>}
[[ $ref == *@sha256:* ]] || { echo "::error::$ref is not a digest reference"; exit 1; }
: "${FEDORA_TOOLS_IMAGE:?set FEDORA_TOOLS_IMAGE}"
public_key=${PUBLIC_KEY:-cosign.pub}

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$(mktemp -d "${RUNNER_TEMP:-/tmp}/host-verify.XXXXXX")
name=host-verify-$$
trap 'podman rm -f -t 0 "$name" &>/dev/null || true; rm -rf "$out"' EXIT
trap 'exit 130' INT TERM

# Key path inside the container must match keyPaths in containers-policy.json.
key_path=$(jq -r '.transports.docker["ghcr.io/rhuze-emryk"][0].keyPaths[0]' \
    "$repo_root/build_files/containers-policy.json")
[[ $key_path == /etc/pki/containers/* ]] || { echo "::error::unexpected keyPaths in policy: $key_path"; exit 1; }

podman run --rm --name "$name" \
    -v "$repo_root/build_files:/policy:ro,z" \
    -v "$(realpath "$public_key"):/key.pub:ro,z" \
    -v "$out:/out:z" \
    -e REF="$ref" -e KEY_PATH="$key_path" \
    "$FEDORA_TOOLS_IMAGE" bash -euo pipefail -c '
        dnf -y install skopeo &>/tmp/dnf.log || { cat /tmp/dnf.log; exit 1; }
        install -D -m 0644 /key.pub "$KEY_PATH"
        skopeo --version
        skopeo copy --quiet \
            --policy /policy/containers-policy.json \
            --registries.d /policy/registries.d \
            "docker://$REF" dir:/out/image
    ' &
# Backgrounded + wait so a cancelled job's SIGTERM is handled immediately and
# the EXIT trap removes the container, instead of waiting out a 5 GB pull.
wait "$!"
echo "✓ $ref accepted by the shipped host signature policy"
