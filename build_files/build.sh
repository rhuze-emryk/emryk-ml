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

# SECURITY-TODO #2: enforce cosign signature verification on pulls from
# ghcr.io/rhuze-emryk. After a user `bootc switch`es to a build that contains
# these files, every subsequent pull from our namespace must verify against
# the public key shipped at /etc/pki/containers/rhuze-emryk.pub or the pull
# is rejected. Other registries (Flathub, docker.io for unsloth, ublue-os
# bases) continue to use the default insecureAcceptAnything so they keep
# working unchanged. Recovery from a misconfiguration is `bootc rollback` to
# the pre-policy deployment.
mkdir -p /etc/pki/containers
install -m 0644 /ctx/cosign.pub /etc/pki/containers/rhuze-emryk.pub

install -m 0644 /ctx/containers-policy.json /etc/containers/policy.json

mkdir -p /etc/containers/registries.d
install -m 0644 /ctx/registries.d/rhuze-emryk.yaml \
    /etc/containers/registries.d/rhuze-emryk.yaml

# SECURITY-TODO #4: Cockpit is reachable over Tailscale only — never over
# the open internet. Fedora's default public zone does not include cockpit,
# so port 9090 is already closed on ethernet/wifi. We additionally ship a
# dedicated "tailscale" firewalld zone (target=ACCEPT) with the tailscale0
# interface pre-assigned, so the operator gets full management access over
# the tailnet the moment tailscaled brings up the interface. Modern
# tailscaled reuses an existing zone of this name instead of creating its
# own, so there is no conflict.
mkdir -p /etc/firewalld/zones
install -m 0644 /ctx/firewalld/zones/tailscale.xml \
    /etc/firewalld/zones/tailscale.xml

# SECURITY-TODO #9: declare the perimeter explicitly. Kinoite inherits
# FedoraWorkstation as the default zone, which allows TCP/UDP 1025-65535
# wide open plus services like cockpit and samba-client — wholly
# inappropriate for an internet-exposed workstation. We:
#  1. Override /etc/firewalld/zones/public.xml to keep only ssh + dhcpv6
#     (mdns removed; cockpit removed; everything else dropped).
#  2. Set public as the default zone, so any NM connection without an
#     explicit zone falls back to this strict baseline.
# Management access continues to flow over the tailscale zone (item #4).
install -m 0644 /ctx/firewalld/zones/public.xml \
    /etc/firewalld/zones/public.xml
firewall-offline-cmd --set-default-zone=public

# SECURITY-TODO #15: assert SELinux is enforcing rather than relying on
# the Fedora default. Fedora ships enforcing by default — we ship an
# explicit /etc/selinux/config so that asserting this is part of the
# image's audit trail. NVIDIA-CDI / podman / distrobox ML workloads
# depend on the `container_use_dri_devices` SELinux boolean being ON,
# which is the Fedora default; we do not change it. Customers who hit
# an SELinux denial they cannot explain can `setenforce 0` for a quick
# diagnostic and file a SECURITY-TODO follow-up.
install -m 0644 /ctx/selinux/config /etc/selinux/config

# SECURITY-TODO #7: enable bootc auto-updates, but as fetch+stage only —
# never auto-reboot. The stock `bootc-fetch-apply-updates.service` runs
# `bootc upgrade --apply`, which can reboot the host any time the timer
# fires (~every 8h with 2h jitter). That is unacceptable for an ML
# workstation where a training job can survive multiple days. The drop-in
# below clears `--apply` so updates download and stage silently; the user
# picks the moment to reboot. Opt out entirely with
# `systemctl disable --now bootc-fetch-apply-updates.timer`.
mkdir -p /etc/systemd/system/bootc-fetch-apply-updates.service.d
install -m 0644 /ctx/systemd/bootc-fetch-apply-updates.service.d/10-emryk.conf \
    /etc/systemd/system/bootc-fetch-apply-updates.service.d/10-emryk.conf

systemctl enable \
    bootc-fetch-apply-updates.timer \
    cockpit.socket \
    emryk-install-flatpaks.service \
    tailscaled.service

# SECURITY-TODO #11: the system podman.socket runs as root and is the
# classic local-root-escalation primitive (mount / into a privileged
# container, you're root). We disable it and enable the *rootless*
# podman.socket globally so every user gets /run/user/$UID/podman/podman.sock
# automatically — scoped to their own privileges, no escalation path.
# Users who specifically need the rootful socket can re-enable with
# `sudo systemctl enable --now podman.socket`.
systemctl --global enable podman.socket
