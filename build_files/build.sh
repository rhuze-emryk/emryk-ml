#!/bin/bash

set -ouex pipefail

curl -fsSL https://pkgs.tailscale.com/stable/fedora/tailscale.repo \
    -o /etc/yum.repos.d/tailscale.repo

dnf5 install -y \
    btop \
    cockpit \
    curl \
    distrobox \
    git \
    htop \
    kde-gtk-config \
    neovim \
    podman-compose \
    podman-docker \
    tailscale \
    vim-enhanced \
    wget \
    wireguard-tools

mkdir -p /etc/modprobe.d

cat > /etc/modprobe.d/blacklist-nouveau.conf <<'EOF'
blacklist nouveau
options nouveau modeset=0
EOF

cat > /etc/modprobe.d/nvidia.conf <<'EOF'
options nvidia-drm modeset=1
options nvidia NVreg_OpenRmEnableUnsupportedGpus=1
EOF

mkdir -p /usr/libexec/emryk

cat > /usr/libexec/emryk/install-flatpaks.sh <<'EOF'
#!/bin/bash
set -euo pipefail
flatpak remote-add --if-not-exists --system flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install --system --noninteractive flathub org.mozilla.firefox
mkdir -p /var/lib/emryk
touch /var/lib/emryk/.flatpaks-installed
EOF

chmod +x /usr/libexec/emryk/install-flatpaks.sh

cat > /etc/systemd/system/emryk-install-flatpaks.service <<'EOF'
[Unit]
Description=Install Emryk default system flatpaks
After=network-online.target flatpak-system-helper.service
Wants=network-online.target flatpak-system-helper.service
ConditionPathExists=!/var/lib/emryk/.flatpaks-installed

[Service]
Type=oneshot
ExecStart=/usr/libexec/emryk/install-flatpaks.sh
RemainAfterExit=yes
StandardOutput=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl enable \
    cockpit.socket \
    emryk-install-flatpaks.service \
    podman.socket \
    tailscaled.service
