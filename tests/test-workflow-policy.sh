#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

workflow_dir=.github/workflows

moving_runner='ubuntu-''latest'
if rg -n "runs-on:[[:space:]]+${moving_runner}" "$workflow_dir"; then
    echo >&2 'A workflow still uses a moving Ubuntu runner label.'
    exit 1
fi

while IFS= read -r uses_line; do
    action_ref=${uses_line##*@}
    action_ref=${action_ref%%[[:space:]#]*}
    [[ $action_ref =~ ^[0-9a-f]{40}$ ]] || {
        echo >&2 "GitHub Action is not pinned by full SHA: $uses_line"
        exit 1
    }
done < <(rg --no-filename '^\s*uses:[[:space:]]+[^./][^@]*@' "$workflow_dir")

disk_workflow=$workflow_dir/build-disk.yml
grep -Fq 'variant:' "$disk_workflow"
grep -Fq 'source-tag:' "$disk_workflow"
unsupported_arch='arm''64'
if grep -Eq "^[[:space:]]+platform:|${unsupported_arch}|ubuntu-24\\.04-arm" "$disk_workflow"; then
    echo >&2 'Disk workflow still exposes a platform/ARM path.'
    exit 1
fi
grep -Eq 'BIB_IMAGE: .*@sha256:[0-9a-f]{64}$' "$disk_workflow"

build_workflow=$workflow_dir/build.yml
# Renovate moves these versions, so assert the pin SHAPE (an exact vX.Y.Z),
# not a specific version — exact values here rot within days. Action SHAs are
# covered by the full-SHA pin loop above.
grep -Eq 'GRYPE_VERSION: "v[0-9]+\.[0-9]+\.[0-9]+"' "$build_workflow"
grep -Eq 'SYFT_VERSION: "v[0-9]+\.[0-9]+\.[0-9]+"' "$build_workflow"
# Deliberate hold (SECURITY-TODO.md P2): v3.1.x breaks --key verification.
# This EXACT pin must scream if anything moves cosign.
grep -Fq "cosign-release: 'v3.0.6'" "$build_workflow"
grep -Fq 'needs: [build_scan, boot_smoke]' "$build_workflow"
boot_smoke_block=$(sed -n '/^  boot_smoke:/,/^  publish:/p' "$build_workflow")
if grep -Fq 'continue-on-error:' <<<"$boot_smoke_block"; then
    echo >&2 'boot_smoke must gate publish, not run advisory (continue-on-error).'
    exit 1
fi
grep -Fq 'persist-credentials: false' <<<"$boot_smoke_block"
# shellcheck disable=SC2016
grep -Fq 'COSIGN_PASSWORD: ${{ secrets.SIGNING_PASSWORD }}' "$build_workflow"
grep -Fq "ssh-keygen -q -t ed25519 -N ''" "$build_workflow"
grep -Fq "sshd -T \\" "$build_workflow"
grep -Fq -- '-h /tmp/emryk-ci-hostkey' "$build_workflow"
# shellcheck disable=SC2016
[[ $(grep -Fc 'modinfo -k "$image_kver" nvidia' "$build_workflow") -eq 2 ]]

sign_line=$(grep -n -- '- name: Sign immutable staged digest' "$build_workflow" | cut -d: -f1)
verify_line=$(grep -n -- '- name: Verify signature with expected active key' "$build_workflow" | cut -d: -f1)
promote_line=$(grep -n -- '- name: Promote verified digest to release tags' "$build_workflow" | cut -d: -f1)
(( sign_line < verify_line && verify_line < promote_line ))

opencode_workflow=$workflow_dir/opencode.yml
[[ $(grep -Fc 'OPENAI_API_KEY:' "$opencode_workflow") -eq 1 ]]
grep -Fq 'needs: authorize' "$opencode_workflow"
grep -Fq "if: needs.authorize.outputs.authorized == 'true'" "$opencode_workflow"
grep -Fq 'Fork pull requests are not authorized' "$opencode_workflow"
grep -Fq 'OWNER|MEMBER|COLLABORATOR' "$opencode_workflow"

host_specific_re='ani''as|glue''tun|torrent-''jail'
if rg -n -i "$host_specific_re" "$workflow_dir/monday-cockpit.yml"; then
    echo >&2 'Repository cockpit still contains host-specific monitoring.'
    exit 1
fi

[[ ! -e package-lock.json ]]
echo 'workflow policy tests passed'
