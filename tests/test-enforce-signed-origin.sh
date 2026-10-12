#!/bin/bash
# Branch tests for enforce-signed-origin.sh against a mocked bootc. The real
# `bootc switch --mutate-in-place` path is exercised by the boot smoke gate.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=${repo_root}/build_files/usr/libexec/emryk/enforce-signed-origin.sh
shipped_policy=${repo_root}/build_files/containers-policy.json

work=$(mktemp -d "${TMPDIR:-/tmp}/emryk-origin-test.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/bin"

cat > "$work/bin/bootc" <<'EOF'
#!/bin/bash
if [[ $1 == status ]]; then
    cat "$MOCK_STATUS"
    exit 0
fi
printf '%s\n' "$*" > "$MOCK_CALLS"
EOF
chmod +x "$work/bin/bootc"

printf 'test-key\n' > "$work/key.pub"
jq --arg key "$work/key.pub" \
    '.transports.docker["ghcr.io/rhuze-emryk"][0].keyPaths = [$key]' \
    "$shipped_policy" > "$work/policy.json"
jq '.default = [{"type": "insecureAcceptAnything"}]' \
    "$work/policy.json" > "$work/insecure-policy.json"
jq --arg key "$work/missing.pub" \
    '.transports.docker["ghcr.io/rhuze-emryk"][0].keyPaths = [$key]' \
    "$shipped_policy" > "$work/missing-key-policy.json"

status() {
    jq -n --arg image "$1" --arg transport "$2" --argjson signature "$3" \
        '{spec: {image: {image: $image, transport: $transport, signature: $signature}}}' \
        > "$work/status.json"
}

# run POLICY EXPECT(switch|none)
run() {
    rm -f "$work/calls"
    PATH="$work/bin:$PATH" MOCK_STATUS="$work/status.json" \
        MOCK_CALLS="$work/calls" EMRYK_POLICY="$1" \
        bash "$script" 2>/dev/null
    if [[ $2 == switch ]]; then
        grep -Fxq "switch --mutate-in-place --enforce-container-sigpolicy --transport registry $3" \
            "$work/calls"
    else
        [[ ! -e $work/calls ]]
    fi
}

latest=ghcr.io/rhuze-emryk/emryk-ml:latest

status "$latest" registry null
run "$work/policy.json" switch "$latest"

status "$latest" registry '"insecure"'
run "$work/policy.json" switch "$latest"

status ghcr.io/rhuze-emryk/emryk-ml-intel@sha256:0123 registry null
run "$work/policy.json" switch ghcr.io/rhuze-emryk/emryk-ml-intel@sha256:0123

status "$latest" registry '"containerPolicy"'
run "$work/policy.json" none

status "$latest" registry '{"ostreeRemote": "fedora"}'
run "$work/policy.json" none

status ghcr.io/ublue-os/kinoite-main:latest registry null
run "$work/policy.json" none

status ghcr.io/rhuze-emryk-evil/emryk-ml:latest registry null
run "$work/policy.json" none

status localhost/emryk-ml:latest containers-storage null
run "$work/policy.json" none

status "$latest" registry null
run "$work/insecure-policy.json" none
run "$work/missing-key-policy.json" none
run "$work/does-not-exist.json" none

echo "enforce-signed-origin tests passed"
