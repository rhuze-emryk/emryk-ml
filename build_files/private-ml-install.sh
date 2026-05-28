#!/bin/bash

set -ouex pipefail

# ---------------------------------------------------------------------------
# Mullvad VPN
# Official Fedora repo. The repo file ships gpgcheck=1 + gpgkey URL, so the
# package signature is verified against Mullvad's published key.
# Ref: https://mullvad.net/en/help/install-mullvad-app-linux
# ---------------------------------------------------------------------------
curl -fsSL https://repository.mullvad.net/rpm/stable/mullvad.repo \
    -o /etc/yum.repos.d/mullvad.repo

# ---------------------------------------------------------------------------
# NVIDIA Container Toolkit
# Required so Podman can pass the host GPU into containers via CDI. The CDI
# spec itself is generated at first boot (see nvidia-cdi-generate.service)
# because nvidia-ctk has to inspect the live kernel modules.
# ---------------------------------------------------------------------------
curl -fsSL https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \
    -o /etc/yum.repos.d/nvidia-container-toolkit.repo

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
