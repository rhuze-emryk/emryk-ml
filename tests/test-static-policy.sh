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

# GPU-less boots must still reach multi-user.target: both NVIDIA units carry
# a widened start-limit window, installed by the nvidia stage only.
for unit in nvidia-cdi-refresh.service nvidia-persistenced.service; do
    drop_in=build_files/systemd/${unit}.d/20-emryk-start-limit.conf
    grep -Eq '^StartLimitIntervalSec=120s$' "$drop_in"
    grep -Eq '^StartLimitBurst=5$' "$drop_in"
    grep -Fq "/ctx/systemd/${unit}.d/20-emryk-start-limit.conf" Containerfile
done
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

# bootc refuses `switch --enforce-container-sigpolicy` when the top-level
# default is insecureAcceptAnything, which silently leaves hosts on
# ostree-unverified-registry. Other registries are allowed per transport.
if ! jq -e '
  .default == [{"type": "reject"}]
    and .transports.docker[""] == [{"type": "insecureAcceptAnything"}]
' build_files/containers-policy.json >/dev/null; then
    echo >&2 "containers-policy.json default must be reject with a docker \"\" catch-all"
    exit 1
fi

if grep -Eq 'cat[[:space:]]*>' build_files/build.sh; then
    echo >&2 "build.sh still generates installed files with heredocs"
    exit 1
fi

echo "static image-policy tests passed"
