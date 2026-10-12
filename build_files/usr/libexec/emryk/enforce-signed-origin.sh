#!/bin/bash
# Make OS updates enforce /etc/containers/policy.json for Emryk images.
#
# `bootc switch <ref>` without --enforce-container-sigpolicy records the
# deployment as ostree-unverified-registry, and every later `bootc upgrade`
# then skips signature verification entirely. Plain switchers,
# bootc-image-builder disk images and Anaconda installs all start that way.
# On each boot, if the booted deployment tracks ghcr.io/rhuze-emryk/* without
# enforcement, rewrite its origin in place: same image reference, no
# download, no new deployment. The next fetch must then verify against the
# shipped key.
#
# Skips (and leaves updates working) when the local policy cannot be
# enforced, e.g. an /etc/containers/policy.json modified locally before the
# reject-by-default policy shipped: flipping the origin then would make every
# future update fail.
set -uo pipefail

readonly NAMESPACE=ghcr.io/rhuze-emryk
readonly POLICY=${EMRYK_POLICY:-/etc/containers/policy.json}

warn() { echo "<4>$*" >&2; }

status_json=$(bootc status --json) || {
    warn "bootc status failed; leaving the update source unchanged"
    exit 0
}

parsed=$(printf '%s' "$status_json" | python3 -c '
import json
import sys

image = (json.load(sys.stdin).get("spec") or {}).get("image") or {}
signature = image.get("signature")
if signature == "containerPolicy" or (
    isinstance(signature, dict) and "ostreeRemote" in signature
):
    state = "enforced"
else:
    state = "unverified"
print(image.get("image") or "-", image.get("transport") or "-", state)
') || {
    warn "could not parse bootc status; leaving the update source unchanged"
    exit 0
}

read -r image transport state <<<"$parsed"

[[ $state == unverified ]] || exit 0
[[ $transport == registry && $image == "$NAMESPACE"/* ]] || exit 0

if ! jq -e --arg ns "$NAMESPACE" '
    (.default | map(.type) | index("insecureAcceptAnything") | not)
    and ((.transports.docker[$ns] // []) | any(.type == "sigstoreSigned"))
' "$POLICY" >/dev/null 2>&1; then
    warn "$POLICY cannot enforce signatures for $NAMESPACE (locally modified?" \
        "compare with /usr/etc/containers/policy.json); updates of $image" \
        "remain UNVERIFIED"
    exit 0
fi

mapfile -t key_paths < <(jq -r --arg ns "$NAMESPACE" '
    .transports.docker[$ns][] | select(.type == "sigstoreSigned") | .keyPaths[]?
' "$POLICY")
if ((${#key_paths[@]} == 0)); then
    warn "no keyPaths for $NAMESPACE in $POLICY; updates of $image remain UNVERIFIED"
    exit 0
fi
for key_path in "${key_paths[@]}"; do
    if [[ ! -s $key_path ]]; then
        warn "signing key $key_path is missing; updates of $image remain UNVERIFIED"
        exit 0
    fi
done

echo "enforcing signature verification for updates of $image"
exec bootc switch --mutate-in-place --enforce-container-sigpolicy \
    --transport registry "$image"
