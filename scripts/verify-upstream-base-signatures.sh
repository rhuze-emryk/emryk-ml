#!/usr/bin/env bash
# Verify that every ghcr.io/ublue-os base image pinned in Containerfile carries
# a valid Universal Blue cosign signature for its exact digest.
#
# A digest pin only records what Renovate saw; it does not prove Universal Blue
# built it. Renovate auto-merges base digest refreshes, and we then sign the
# result with our own key, so an unsigned upstream push would otherwise flow
# straight to customers. Upstream ships a primary and a backup key (the backup
# exists for rotation); either is accepted. Both are vendored under
# upstream-keys/ and tracked against upstream by vendor-drift-watch.yml.
#
# Usage: scripts/verify-upstream-base-signatures.sh [Containerfile] [key-dir]
set -euo pipefail

containerfile=${1:-Containerfile}
key_dir=${2:-upstream-keys}
keys=("$key_dir/ublue-os.pub" "$key_dir/ublue-os-backup.pub")

for key in "${keys[@]}"; do
    [[ -s $key ]] || { echo "::error::missing vendored key $key"; exit 1; }
done

mapfile -t refs < <(grep -oP '^FROM\s+\Kghcr\.io/ublue-os/\S+' "$containerfile")
(( ${#refs[@]} > 0 )) || { echo "::error::no ghcr.io/ublue-os FROM lines in $containerfile"; exit 1; }

failed=0
for ref in "${refs[@]}"; do
    [[ $ref == *@sha256:* ]] || { echo "::error::$ref is not digest-pinned"; failed=1; continue; }
    image=${ref%%@*}
    image=${image%:*}
    target="${image}@${ref#*@}"
    verified=''
    for key in "${keys[@]}"; do
        if cosign verify --key "$key" --new-bundle-format=false "$target" >/dev/null 2>&1; then
            verified=$key
            break
        fi
    done
    if [[ -n $verified ]]; then
        echo "✓ $target signed by $(basename "$verified")"
    else
        echo "::error::$target has no valid Universal Blue signature (tried ${keys[*]}). Do not build on it: confirm upstream's signing status before re-pinning."
        failed=1
    fi
done
exit "$failed"
