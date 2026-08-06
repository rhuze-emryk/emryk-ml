#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

if grep -Fq 'blacklist nouveau' build_files/build.sh; then
    echo >&2 "shared build script contains the nouveau blacklist"
    exit 1
fi

intel_stage=$(sed -n '/^FROM kinoite AS intel$/,/^FROM kinoite AS nvidia$/p' \
    Containerfile | sed '/^#/d; /^FROM kinoite AS nvidia$/d')
if grep -Eqi '(nouveau|nvidia)' <<<"$intel_stage"; then
    echo >&2 "Intel stage contains NVIDIA-specific content"
    exit 1
fi

grep -Fq '/ctx/modprobe.d/blacklist-nouveau.conf' Containerfile
grep -Fq 'gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-tailscale' \
    build_files/tailscale.repo
gpg --batch --show-keys build_files/tailscale-repo.gpg >/dev/null

jq -e '
  .transports.docker["ghcr.io/rhuze-emryk"]
  | length == 1
    and .[0].type == "sigstoreSigned"
    and (.[0] | has("keyPaths"))
    and (.[0] | has("keyPath") | not)
' build_files/containers-policy.json >/dev/null

if grep -Eq 'cat[[:space:]]*>' build_files/build.sh; then
    echo >&2 "build.sh still generates installed files with heredocs"
    exit 1
fi

echo "static image-policy tests passed"
