#!/bin/bash

set -ouex pipefail

# nouveau must not claim the GPU before the NVIDIA driver; ublue-os-nvidia-addons
# does not ship this blacklist, so we create it explicitly.
echo -e "blacklist nouveau\noptions nouveau modeset=0" \
    > /usr/lib/modprobe.d/blacklist-nouveau.conf

# Vendored from https://pkgs.tailscale.com/stable/fedora/tailscale.repo and
# checked into build_files/. Freezes baseurl + gpgkey URLs at a state we have
# reviewed — a CDN-level compromise that swaps either field cannot affect us
# without a PR landing in this repo first. (SECURITY-TODO #6)
cp /ctx/tailscale.repo /etc/yum.repos.d/tailscale.repo

dnf5 install -y \
    btop \
    cockpit \
    curl \
    distrobox \
    fuse \
    fuse-libs \
    gh \
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

# SSH hardening — key-only auth, no root login over SSH. Cloud workstations
# with public IPs get scanned constantly; password auth and root login are
# the two biggest brute-force surfaces. Drops into sshd_config.d so it
# overrides Fedora defaults without editing the main sshd_config. Users who
# need different behavior can drop their own file with a higher-numbered
# prefix. (SECURITY-TODO #5)
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/10-emryk.conf <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
EOF

systemctl enable \
    cockpit.socket \
    emryk-install-flatpaks.service \
    podman.socket \
    tailscaled.service
