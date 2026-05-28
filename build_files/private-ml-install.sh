#!/bin/bash

set -ouex pipefail

# ---------------------------------------------------------------------------
# Mullvad VPN
# Vendored from https://repository.mullvad.net/rpm/stable/mullvad.repo and
# checked into build_files/. Freezes baseurl + gpgkey URLs at a state we have
# reviewed — a CDN-level compromise that swaps either field cannot affect us
# without a PR landing in this repo first. The repo file ships gpgcheck=1
# with a gpgkey URL, so the package signature is still verified against
# Mullvad's published key at install time.
# Ref: https://mullvad.net/en/help/install-mullvad-app-linux
# ---------------------------------------------------------------------------
cp /ctx/mullvad.repo /etc/yum.repos.d/mullvad.repo

# ---------------------------------------------------------------------------
# NVIDIA Container Toolkit
# Vendored from
#   https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo
# and checked into build_files/ — same threat model as the Mullvad repo
# above. The vendored file includes both the stable (enabled) and
# experimental (disabled) sections verbatim from upstream; only the stable
# section is consumed by the dnf install below. The CDI spec itself is
# generated at first boot (see nvidia-cdi-generate.service) because
# nvidia-ctk has to inspect the live kernel modules.
# ---------------------------------------------------------------------------
cp /ctx/nvidia-container-toolkit.repo /etc/yum.repos.d/nvidia-container-toolkit.repo

# On bootc images /opt is a symlink to /var/opt, and /var/opt does not exist
# in the build container. Any RPM that writes under /opt (Mullvad installs to
# "/opt/Mullvad VPN/") fails with cpio: mkdir failed unless the symlink target
# is pre-created. Same pattern Bazzite uses for Steam.
mkdir -p /var/opt

dnf5 install -y \
    mullvad-vpn \
    nvidia-container-toolkit

# ---------------------------------------------------------------------------
# NVIDIA CDI spec generator
# Runs at every boot so the spec stays in sync with the running driver after
# a base-image rebase. nvidia-ctk inspects loaded modules, so this can only
# run on a live system — not at image build time.
# ---------------------------------------------------------------------------
cat > /etc/systemd/system/nvidia-cdi-generate.service <<'EOF'
[Unit]
Description=Generate NVIDIA CDI spec for Podman GPU passthrough
Documentation=https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/cdi-support.html
After=local-fs.target

[Service]
Type=oneshot
ExecStartPre=/usr/bin/mkdir -p /etc/cdi
ExecStart=/usr/bin/nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# ---------------------------------------------------------------------------
# Enable services
# Mullvad daemon runs at boot (user still has to log in once with their
# account number). CDI generator runs once per boot.
# ---------------------------------------------------------------------------
systemctl enable \
    mullvad-daemon.service \
    nvidia-cdi-generate.service
