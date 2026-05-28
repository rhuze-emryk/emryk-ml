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

# On bootc images /opt is a symlink to /var/opt, and /var/opt does not exist
# in the build container. Any RPM that writes under /opt (Mullvad installs to
# "/opt/Mullvad VPN/") fails with cpio: mkdir failed unless the symlink target
# is pre-created. Same pattern Bazzite uses for Steam.
mkdir -p /var/opt

dnf5 install -y mullvad-vpn

# ---------------------------------------------------------------------------
# Enable services
# Mullvad daemon runs at boot (user still has to log in once with their
# account number). NVIDIA container toolkit + the nvidia-cdi-generate
# service now ship in the base image (see build_files/build.sh), so this
# variant only needs to enable Mullvad.
# ---------------------------------------------------------------------------
systemctl enable mullvad-daemon.service
