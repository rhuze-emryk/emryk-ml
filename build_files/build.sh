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

# NVIDIA Container Toolkit and its CDI generator are NOT installed here: the
# base image's upstream akmods nvidia-install.sh already installs
# `nvidia-container-toolkit` (signature-verified — it sets gpgcheck=1 on its
# own toolkit repo) and enables `ublue-nvctk-cdi.service` to regenerate the
# CDI spec at boot. Duplicating either here was a no-op install plus a second
# oneshot racing upstream's unit to write /etc/cdi/nvidia.yaml (SECURITY-TODO
# #25). We rely on upstream for both; we pin the akmods image by digest.
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

# SECURITY-TODO #32: nudge the operator when an update is staged. The
# bootc-fetch timer (#7) fetches + stages silently and never reboots, so a
# fix can sit downloaded-but-inactive with no signal. This oneshot writes a
# login banner to /run/motd.d (tmpfs) when bootc reports a staged deployment,
# so every SSH/console login sees it; it self-clears on the reboot that
# applies the update. Best-effort kernel-change note. A timer re-evaluates so
# the banner appears/disappears as the staged state changes. No auto-reboot.
cat > /usr/libexec/emryk/update-nudge.sh <<'NUDGE'
#!/bin/bash
# Write or clear the staged-update login nudge. Parses `bootc status` with
# python3 (always present on Kinoite) to avoid a jq dependency. Resilient by
# design (no `set -e`): any failure degrades to clearing or to the generic
# message, never an error to the operator.
set -uo pipefail

MOTD=/run/motd.d/95-emryk-update.motd

status_json=$(bootc status --json 2>/dev/null) || { rm -f "$MOTD"; exit 0; }

# Emits: "<yes|no> <ostree-checksum> <deploy-serial>"
parsed=$(printf '%s' "$status_json" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("no  "); sys.exit(0)
staged = (d.get("status") or {}).get("staged")
if not staged:
    print("no  "); sys.exit(0)
o = staged.get("ostree") or {}
serial = o.get("deploySerial")
print("yes", o.get("checksum") or "", "" if serial is None else serial)
' 2>/dev/null) || { rm -f "$MOTD"; exit 0; }

read -r has_staged checksum serial <<<"$parsed"

if [ "${has_staged:-no}" != "yes" ]; then
    rm -f "$MOTD"
    exit 0
fi

# Best-effort: does the staged deployment carry a different kernel? Read the
# staged deployment's own modules dir so a rollback's kernel can't be
# mistaken for the staged one. If the schema differs or the path is missing,
# staged_kver stays empty and we fall back to the generic message.
running_kver=$(uname -r)
staged_kver=""
if [ -n "${checksum:-}" ]; then
    for moddir in /ostree/deploy/*/deploy/"${checksum}.${serial:-0}"/usr/lib/modules/*/; do
        [ -d "$moddir" ] || continue
        kv=${moddir%/}; kv=${kv##*/}
        [ "$kv" != "$running_kver" ] && staged_kver=$kv
    done
fi

mkdir -p /run/motd.d
{
    echo ""
    echo "  *** A system update has been downloaded and staged. ***"
    if [ -n "$staged_kver" ]; then
        echo "      It includes a new kernel (${running_kver} -> ${staged_kver});"
        echo "      the NVIDIA driver reloads on reboot."
    fi
    echo "      Reboot when convenient to apply it:  sudo systemctl reboot"
    echo "      Nothing reboots on its own; running jobs are safe until you do."
    echo ""
} > "$MOTD"
NUDGE
chmod +x /usr/libexec/emryk/update-nudge.sh

cat > /etc/systemd/system/emryk-update-nudge.service <<'EOF'
[Unit]
Description=Refresh the staged-update login nudge (/run/motd.d)
Documentation=https://github.com/rhuze-emryk/emryk-ml/blob/main/UPDATING.md
After=bootc-fetch-apply-updates.service

[Service]
Type=oneshot
ExecStart=/usr/libexec/emryk/update-nudge.sh
EOF

cat > /etc/systemd/system/emryk-update-nudge.timer <<'EOF'
[Unit]
Description=Periodically refresh the staged-update login nudge

[Timer]
OnBootSec=2min
OnUnitActiveSec=30min
Persistent=true

[Install]
WantedBy=timers.target
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
# is rejected. Other registries (Flathub, docker.io, ublue-os
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

# SECURITY-TODO #17: assert wheel-requires-password rather than inherit it.
# sudoers drop-ins are loaded alphabetically; the last matching rule wins,
# so the 99- prefix guarantees this file overrides anything an upstream
# package ever ships under a lower prefix. Mode MUST be 0440 or sudo
# refuses to load the file.
install -m 0440 /ctx/sudoers.d/99-emryk-wheel \
    /etc/sudoers.d/99-emryk-wheel

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
    emryk-update-nudge.timer \
    flatpak-system-update.timer \
    tailscaled.service

# SECURITY-TODO #11: the system podman.socket runs as root and is the
# classic local-root-escalation primitive (mount / into a privileged
# container, you're root). We disable it and enable the *rootless*
# podman.socket globally so every user gets /run/user/$UID/podman/podman.sock
# automatically — scoped to their own privileges, no escalation path.
# Users who specifically need the rootful socket can re-enable with
# `sudo systemctl enable --now podman.socket`.
systemctl --global enable podman.socket
