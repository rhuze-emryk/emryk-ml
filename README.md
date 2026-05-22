# Emryk ML

[![Build Status](https://github.com/rhuze-emryk/emryk-ml/actions/workflows/build.yml/badge.svg)](https://github.com/rhuze-emryk/emryk-ml/actions/workflows/build.yml)

A managed [bootc](https://github.com/bootc-dev/bootc) image for cloud ML workstations. Built on [Universal Blue's](https://universal-blue.org/) `kinoite-main` (Fedora Kinoite + UBlue fixes) with NVIDIA open kernel modules, KDE Plasma, and a container-first dev toolchain pre-configured.

This is the public image foundation for the [Emryk Workstation](https://emryk.com) product. It builds to `ghcr.io/rhuze-emryk/emryk-ml` on every push to `main`.

## What's included

**Base:** `ghcr.io/ublue-os/kinoite-main:latest` — stock Fedora Kinoite with UBlue's RPMFusion, hardware quirk fixes, and `bootc` integration.

**NVIDIA:** Open kernel modules via `ghcr.io/ublue-os/akmods-nvidia-open:latest`, installed in a multi-stage build so the pre-built modules match the base image's kernel exactly.

**Packages installed on top of the base:**

| Package | Purpose |
|---|---|
| `tailscale` | Team VPN |
| `wireguard-tools` | WireGuard primitives |
| `cockpit` | Remote browser-based management |
| `distrobox` | Per-project containers on top of the immutable base |
| `podman-compose` / `podman-docker` | Container workflows; Docker socket compatibility via Podman |
| `neovim` / `vim-enhanced` | Editors |
| `btop` / `htop` | System monitoring |
| `kde-gtk-config` | GTK app theming integration for KDE |
| `gh` | GitHub CLI |
| `git` / `curl` / `wget` | Standard tooling |

**Systemd services enabled:** `tailscaled`, `cockpit.socket`, `podman.socket`

**Flatpaks:** Firefox is installed from Flathub at first boot via a oneshot systemd service (`emryk-install-flatpaks.service`). Network is required on first boot for this step.

**NVIDIA modprobe config:** nouveau blacklisted; `nvidia-drm modeset=1` set; open module enabled for unsupported GPUs.

## Using the image

From any bootc system:

```bash
sudo bootc switch ghcr.io/rhuze-emryk/emryk-ml:latest
```

Reboot to apply.

### Variants

| Tag | Description |
|---|---|
| `:latest` | Default image. |
| `:latest-antigravity` | `:latest` plus [Google Antigravity](https://antigravity.google/) IDE preinstalled. Built manually on demand. |

Switch between variants with `bootc switch`; rollback to the previous deployment with `sudo bootc rollback`. `/var` and `/home` are preserved across switches.

## Verifying the image

Images are signed with [cosign](https://github.com/sigstore/cosign). The public key is `cosign.pub` in this repository.

```bash
cosign verify \
    --key https://raw.githubusercontent.com/rhuze-emryk/emryk-ml/main/cosign.pub \
    ghcr.io/rhuze-emryk/emryk-ml:latest
```

## Tags

| Tag | Description |
|---|---|
| `latest` | Current tested release |
| `YYYYMMDD` | Date-stamped build |
| `latest.YYYYMMDD` | Same build, aliased |
| `latest-antigravity` | `latest` + Google Antigravity IDE (manual dispatch) |
| `latest-antigravity.YYYYMMDD` | Date-stamped antigravity build |

PRs produce a SHA-tagged image that is not pushed to the registry.

## Building locally

Requires [just](https://just.systems) and Podman.

```bash
just build
```

To build a QCOW2 disk image:

```bash
just build-qcow2
```

## Repository layout

```
Containerfile                       Multi-stage build: akmods-nvidia-open → kinoite-main
Containerfile.antigravity           Antigravity variant: FROM :latest + install layer
build_files/build.sh                Package installs, repo setup, service config
build_files/antigravity-install.sh  Antigravity repo + package install
.github/workflows/
  build.yml                         Build, push to GHCR, sign with cosign
  build-antigravity.yml             Manual dispatch: build :latest-antigravity
  build-disk.yml                    Disk image builds (qcow2, raw, iso)
cosign.pub                          Public signing key
```

## What this image is not

- Not a hobbyist image. Customizability is for the maintainer, not the user.
- Not a gaming image. See [Bazzite](https://bazzite.gg/) for that.
- Not a general-purpose desktop. Packages are chosen for ML/cloud workstation use.
- Not GNOME. KDE only.
