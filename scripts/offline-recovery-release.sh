#!/bin/bash
# Promote a VM-gated incident image using the offline recovery signer. Run this
# only from the offline recovery procedure in KEY-POLICY.md. The private key
# path and COSIGN_PASSWORD must never be stored in this repository or GitHub.
set -euo pipefail

usage() {
    echo >&2 "usage: RECOVERY_PRIVATE_KEY=/outside/repo/key COSIGN_PASSWORD=... $0 IMAGE@sha256:DIGEST TAG [TAG ...]"
    exit 2
}

(( $# >= 2 )) || usage
readonly source_ref=$1
shift
readonly recovery_private_key=${RECOVERY_PRIVATE_KEY:-}
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly repo_root
readonly recovery_public_key=${repo_root}/recovery-cosign.pub

[[ $source_ref =~ ^[^[:space:]@]+@sha256:[a-f0-9]{64}$ ]] || usage
[[ -n $recovery_private_key && -f $recovery_private_key ]] || {
    echo >&2 'RECOVERY_PRIVATE_KEY must name the offline encrypted private key.'
    exit 2
}
[[ -n ${COSIGN_PASSWORD:-} ]] || {
    echo >&2 'COSIGN_PASSWORD must be supplied from an offline interactive session.'
    exit 2
}
[[ -s $recovery_public_key ]] || {
    echo >&2 'The committed recovery-cosign.pub trust asset is missing.'
    exit 1
}

if ! cosign version 2>&1 | grep -Eq 'GitVersion:[[:space:]]+v3\.0\.6([[:space:]]|$)'; then
    echo >&2 'Recovery release requires the reviewed cosign v3.0.6 binary.'
    exit 1
fi

private_real=$(realpath "$recovery_private_key")
case "$private_real" in
    "$repo_root"|"$repo_root"/*)
        echo >&2 'The recovery private key must remain outside the repository.'
        exit 1
        ;;
esac

for tag in "$@"; do
    [[ $tag =~ ^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$ ]] || {
        echo >&2 "invalid OCI tag: $tag"
        exit 2
    }
done

image=${source_ref%@*}
cosign sign -y \
    --key "$private_real" \
    --new-bundle-format=false \
    --use-signing-config=false \
    "$source_ref"
cosign verify --key "$recovery_public_key" --new-bundle-format=false \
    "$source_ref" >/dev/null

for tag in "$@"; do
    skopeo copy --preserve-digests \
        "docker://${source_ref}" \
        "docker://${image}:${tag}"
    echo "Promoted recovery-signed ${source_ref} -> ${image}:${tag}"
done
