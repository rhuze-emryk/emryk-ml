#!/bin/bash
# Disposable cryptographic rehearsal for the alternative keyPaths semantics.
# It never uses production keys. A complete operational rehearsal additionally
# boots the transition and incident images through build.yml's VM smoke gate.
set -euo pipefail

for command_name in buildah cosign jq podman skopeo; do
    command -v "$command_name" >/dev/null || {
        echo >&2 "missing required command: $command_name"
        exit 1
    }
done

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/emryk-key-rehearsal.XXXXXXXX")
registry_name=emryk-key-rehearsal-$RANDOM
registry_port=${REGISTRY_PORT:-55000}
cleanup() {
    podman rm -f "$registry_name" >/dev/null 2>&1 || true
    rm -rf -- "$work_dir"
}
trap cleanup EXIT

podman run --detach --rm --name "$registry_name" \
    --publish "127.0.0.1:${registry_port}:5000" docker.io/library/registry:2 \
    >/dev/null
registry="localhost:${registry_port}/emryk"

make_key() {
    local name=$1
    mkdir -p "$work_dir/$name"
    COSIGN_PASSWORD=rehearsal-only cosign generate-key-pair \
        --output-key-prefix "$work_dir/$name/cosign" >/dev/null
}

make_image() {
    local name=$1
    local container
    container=$(buildah from scratch)
    buildah config --label "org.emryk.rehearsal=$name" "$container"
    buildah commit "$container" "$registry:$name" >/dev/null
    buildah rm "$container" >/dev/null
    buildah push --tls-verify=false "$registry:$name" >/dev/null
    skopeo inspect --tls-verify=false --format '{{.Digest}}' \
        "docker://$registry:$name"
}

for key_name in old next recovery fresh unrelated; do
    make_key "$key_name"
done

cosign_sign_args=(--tlog-upload=false)
if cosign version 2>&1 | grep -Eq 'GitVersion:[[:space:]]+v3\.'; then
    # Cosign v3 enables its service config by default. Disable it explicitly
    # for this offline, legacy-attachment policy rehearsal.
    cosign_sign_args+=(--use-signing-config=false --new-bundle-format=false)
fi

declare -A references=()
for image_name in old next recovery fresh unrelated unsigned; do
    digest=$(make_image "$image_name")
    references[$image_name]="${registry}@${digest}"
done

for signed_name in old next recovery fresh unrelated; do
    COSIGN_PASSWORD=rehearsal-only cosign sign -y --allow-insecure-registry \
        "${cosign_sign_args[@]}" \
        --key "$work_dir/$signed_name/cosign.key" "${references[$signed_name]}" \
        >/dev/null
done

mkdir -p "$work_dir/registries.d"
printf 'docker:\n  %s:\n    use-sigstore-attachments: true\n' "localhost:${registry_port}" \
    > "$work_dir/registries.d/default.yaml"

write_policy() {
    local output=$1
    shift
    jq -n --arg scope "localhost:${registry_port}/emryk" \
        --argjson keys "$(printf '%s\n' "$@" | jq -R . | jq -s .)" '
          {
            default: [{type: "reject"}],
            transports: {
              docker: {
                ($scope): [{
                  type: "sigstoreSigned",
                  keyPaths: $keys,
                  signedIdentity: {type: "matchRepository"}
                }]
              }
            }
          }
        ' > "$output"
}

policy_copy() {
    local policy=$1
    local name=$2
    local destination=$3
    skopeo --registries.d "$work_dir/registries.d" copy \
        --policy "$policy" --src-tls-verify=false \
        "docker://${references[$name]}" "dir:$destination" >/dev/null
}

write_policy "$work_dir/transition-policy.json" \
    "$work_dir/old/cosign.pub" \
    "$work_dir/next/cosign.pub" \
    "$work_dir/recovery/cosign.pub"
for trusted_name in old next recovery; do
    policy_copy "$work_dir/transition-policy.json" "$trusted_name" \
        "$work_dir/transition-$trusted_name"
done
for rejected_name in unrelated unsigned; do
    if policy_copy "$work_dir/transition-policy.json" "$rejected_name" \
        "$work_dir/should-reject-$rejected_name"; then
        echo >&2 "transition policy accepted $rejected_name"
        exit 1
    fi
done

write_policy "$work_dir/incident-policy.json" \
    "$work_dir/recovery/cosign.pub" \
    "$work_dir/fresh/cosign.pub"
for trusted_name in recovery fresh; do
    policy_copy "$work_dir/incident-policy.json" "$trusted_name" \
        "$work_dir/incident-$trusted_name"
done
if policy_copy "$work_dir/incident-policy.json" old "$work_dir/compromised-old"; then
    echo >&2 'incident policy still accepted the removed old signer'
    exit 1
fi

echo 'ephemeral planned and incident key-policy rehearsal passed'
