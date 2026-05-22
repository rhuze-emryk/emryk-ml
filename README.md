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
| `:latest-private-ml` | `:latest` plus [Mullvad VPN](https://mullvad.net/) daemon and [Unsloth Studio](https://unsloth.ai/docs/new/studio) preconfigured. Built manually on demand. |

Switch between variants with `bootc switch`; rollback to the previous deployment with `sudo bootc rollback`. `/var` and `/home` are preserved across switches.

### `:latest-private-ml` first-run

**Mullvad.** The `mullvad-daemon` service starts at boot but the system has no account credentials. Log in once with:

```bash
mullvad account login <YOUR-ACCOUNT-NUMBER>
mullvad connect
```

Or use the Mullvad GUI app, also installed.

**Unsloth Studio.** Not started automatically. Launch it from the application menu ("Start Unsloth Studio") or run `/usr/libexec/emryk/launch-unsloth-studio.sh`. The first launch pulls the `docker.io/unsloth/unsloth` image (multi-GB) and can take several minutes; subsequent launches are fast. The UI binds to `http://127.0.0.1:8888` only — not exposed on the LAN. Persistent state lives in the Podman named volume `unsloth-studio-data`.

## Remote management

Cockpit (browser-based system management) is installed and enabled on every build, but is **only reachable over Tailscale** — never over the LAN or the open internet.

Mechanism: Fedora's default `public` firewalld zone does not allow port 9090, so Cockpit is closed to ethernet/wifi. The image additionally ships a dedicated `tailscale` firewalld zone (`target=ACCEPT`) with `tailscale0` pre-assigned, so once both ends of the tailnet are up the host's management plane is available to the operator and nobody else.

Access it at:

```
https://<host>.<tailnet-name>.ts.net:9090
```

or via the host's tailnet IP (`https://100.x.y.z:9090`). If you ever need Cockpit reachable somewhere other than the tailnet, you'll have to explicitly add the `cockpit` service to another firewalld zone — and please reconsider whether you actually want that.

## Updates

`bootc-fetch-apply-updates.timer` is enabled on every build, and runs roughly every 8 hours (with 2h randomised jitter). It **fetches and stages** updates from the registry but **does not reboot** — a customer training job can run for days, and a surprise unattended reboot would vaporise it.

When an update has been staged, the change takes effect on the next reboot. To check what's queued:

```bash
bootc status
```

To force-apply staged updates right now: `sudo systemctl reboot`. To roll back to the previous deployment if the new one misbehaves: `sudo bootc rollback && sudo systemctl reboot`. To opt out of auto-fetching entirely:

```bash
sudo systemctl disable --now bootc-fetch-apply-updates.timer
```

## Verifying the image

Images are signed with [cosign](https://github.com/sigstore/cosign). The public key is `cosign.pub` in this repository.

```bash
cosign verify \
    --key https://raw.githubusercontent.com/rhuze-emryk/emryk-ml/main/cosign.pub \
    ghcr.io/rhuze-emryk/emryk-ml:latest
```

**Enforced on installed systems.** Builds containing this policy ship
`/etc/containers/policy.json` requiring sigstore-signed pulls from
`ghcr.io/rhuze-emryk/`, verified against the cosign public key installed at
`/etc/pki/containers/rhuze-emryk.pub`. Once you `bootc switch` to such a build,
any subsequent pull from this namespace that fails verification is rejected
before being staged for boot. Other registries (Flathub, Docker Hub, ublue-os)
continue to use the default accept-anything policy. If a misconfiguration ever
breaks pulls, `sudo bootc rollback` returns you to the previous deployment,
which uses the older policy.

## Tags

| Tag | Description |
|---|---|
| `latest` | Current tested release |
| `YYYYMMDD` | Date-stamped build |
| `latest.YYYYMMDD` | Same build, aliased |
| `latest-private-ml` | `latest` + Mullvad VPN + Unsloth Studio (manual dispatch) |
| `latest-private-ml.YYYYMMDD` | Date-stamped private-ml build |

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
Containerfile.private-ml            private-ml variant: FROM :latest + install layer
build_files/build.sh                Package installs, repo setup, service config
build_files/private-ml-install.sh   Mullvad + NVIDIA container toolkit + Unsloth Studio Quadlet
.github/workflows/
  build.yml                         Build, push to GHCR, sign with cosign
  build-private-ml.yml              Manual dispatch: build :latest-private-ml
  build-disk.yml                    Disk image builds (qcow2, raw, iso)
cosign.pub                          Public signing key
```

## What this image is not

- Not a hobbyist image. Customizability is for the maintainer, not the user.
- Not a gaming image. See [Bazzite](https://bazzite.gg/) for that.
- Not a general-purpose desktop. Packages are chosen for ML/cloud workstation use.
- Not GNOME. KDE only.
