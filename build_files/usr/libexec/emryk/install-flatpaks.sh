#!/bin/bash
set -euo pipefail

flatpak remote-add --if-not-exists --system flathub \
    https://flathub.org/repo/flathub.flatpakrepo
flatpak install --system --noninteractive flathub org.mozilla.firefox
mkdir -p /var/lib/emryk
touch /var/lib/emryk/.flatpaks-installed
