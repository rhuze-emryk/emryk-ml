#!/bin/bash

set -ouex pipefail

# Both the repository configuration and its signing key are reviewed and
# vendored. The repository references only the local key installed below.
install -D -m 0644 /ctx/tailscale-repo.gpg \
    /etc/pki/rpm-gpg/RPM-GPG-KEY-tailscale
install -D -m 0644 /ctx/tailscale.repo \
    /etc/yum.repos.d/tailscale.repo

# NVIDIA Container Toolkit and its CDI generator are NOT installed here: the
# base image's upstream akmods nvidia-install.sh already installs
# `nvidia-container-toolkit` (signature-verified — it sets gpgcheck=1 on its
# own toolkit repo) and enables `ublue-nvctk-cdi.service` to regenerate the
# CDI spec at boot. Duplicating either here was a no-op install plus a second
# oneshot racing upstream's unit to write /etc/cdi/nvidia.yaml. We rely on
# upstream for both and pin the akmods image by digest.
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

install -D -m 0755 /ctx/usr/libexec/emryk/install-flatpaks.sh \
    /usr/libexec/emryk/install-flatpaks.sh
install -D -m 0755 /ctx/usr/libexec/emryk/update-nudge.sh \
    /usr/libexec/emryk/update-nudge.sh

install -D -m 0644 /ctx/systemd/emryk-install-flatpaks.service \
    /etc/systemd/system/emryk-install-flatpaks.service
install -D -m 0644 /ctx/systemd/emryk-update-nudge.service \
    /etc/systemd/system/emryk-update-nudge.service
install -D -m 0644 /ctx/systemd/emryk-update-nudge.timer \
    /etc/systemd/system/emryk-update-nudge.timer

# SSH hardening — key-only auth, no root login over SSH. SSH is reachable over
# the tailscale zone only (see the firewall config below, and #36), so this is
# defense-in-depth on the tailnet path rather than a shield against open-internet
# scanning. Drops into sshd_config.d so it overrides Fedora defaults without
# editing the main sshd_config. Users who need different behavior can drop their
# own file with a higher-numbered prefix.
install -D -m 0644 /ctx/ssh/sshd_config.d/10-emryk.conf \
    /etc/ssh/sshd_config.d/10-emryk.conf

# Enforce cosign signature verification on pulls from
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

# Cockpit is reachable over Tailscale only in the shipped firewall policy,
# not over the open internet. Fedora's default public zone does not include cockpit,
# so port 9090 is already closed on ethernet/wifi. We additionally ship a
# dedicated "tailscale" firewalld zone (target=ACCEPT) with the tailscale0
# interface pre-assigned, so the operator gets full management access over
# the tailnet the moment tailscaled brings up the interface. Modern
# tailscaled reuses an existing zone of this name instead of creating its
# own, so there is no conflict.
mkdir -p /etc/firewalld/zones
install -m 0644 /ctx/firewalld/zones/tailscale.xml \
    /etc/firewalld/zones/tailscale.xml

# Declare the perimeter explicitly. Kinoite inherits
# FedoraWorkstation as the default zone, which allows TCP/UDP 1025-65535
# wide open plus services like cockpit and samba-client — wholly
# inappropriate for an internet-exposed workstation. We:
#  1. Override /etc/firewalld/zones/public.xml to keep only dhcpv6-client
#     (ssh moved to the tailscale zone per #36; mdns, cockpit, and everything
#     else dropped).
#  2. Set public as the default zone, so any NM connection without an
#     explicit zone falls back to this strict baseline.
# Management access — SSH and Cockpit — flows over the tailscale zone
# (items #4, #36).
install -m 0644 /ctx/firewalld/zones/public.xml \
    /etc/firewalld/zones/public.xml
firewall-offline-cmd --set-default-zone=public

# Disable the Plasma onscreen keyboard by default. Fedora 44's Plasma 6.6
# base ships plasma-keyboard (KDE's new touch OSK, Maliit's replacement) as
# the compiled-in default input method, and it auto-raises at the login
# greeter and in-session on first boot — confusing and broken-looking on a
# non-touch ML workstation. The package cannot be removed (plasma-desktop's
# dependency chain pulls it back in), so we ship /etc/xdg/kwinrc with an
# explicitly-empty InputMethod, which overrides the compiled-in default for
# both the plasma-login greeter and user sessions. Per-user opt-in via
# System Settings still works — user config overrides /etc/xdg.
mkdir -p /etc/xdg
install -m 0644 /ctx/kde/kwinrc /etc/xdg/kwinrc

# Assert SELinux is enforcing rather than relying on
# the Fedora default. Fedora ships enforcing by default — we ship an
# explicit /etc/selinux/config so that asserting this is part of the
# image's audit trail. NVIDIA-CDI / podman / distrobox ML workloads
# depend on the `container_use_dri_devices` SELinux boolean being ON,
# which is the Fedora default; we do not change it. Customers who hit
# an SELinux denial they cannot explain can `setenforce 0` for a quick
# diagnostic and file a security report.
install -m 0644 /ctx/selinux/config /etc/selinux/config

# Assert wheel-requires-password rather than inherit it.
# sudoers drop-ins are loaded alphabetically; the last matching rule wins,
# so the 99- prefix guarantees this file overrides anything an upstream
# package ever ships under a lower prefix. Mode MUST be 0440 or sudo
# refuses to load the file.
install -m 0440 /ctx/sudoers.d/99-emryk-wheel \
    /etc/sudoers.d/99-emryk-wheel

# Enable bootc auto-updates, but as fetch+stage only —
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

# Enable the services the image relies on. sshd.service in particular MUST be
# enabled explicitly: the inherited 81-desktop systemd preset disables it (and
# sorts before 90-default's enable, so it wins). Without this, an install would
# ship the SSH hardening (#5) and open the firewall but never run sshd — TCP:22
# refused on a fresh boot, SSH reachable only via systemd-ssh-generator's
# vsock/unix sockets. SSH is scoped to the tailscale zone by the firewall
# through the shipped Tailscale firewall zone.
systemctl enable \
    bootc-fetch-apply-updates.timer \
    cockpit.socket \
    emryk-install-flatpaks.service \
    emryk-update-nudge.timer \
    flatpak-system-update.timer \
    sshd.service \
    tailscaled.service

# The system podman.socket runs as root and is a local privilege boundary: a
# classic local-root-escalation primitive (mount / into a privileged
# container, you're root). We disable it and enable the *rootless*
# podman.socket globally so every user gets /run/user/$UID/podman/podman.sock
# automatically — scoped to their own privileges, no escalation path.
# Users who specifically need the rootful socket can re-enable with
# `sudo systemctl enable --now podman.socket`.
systemctl --global enable podman.socket
