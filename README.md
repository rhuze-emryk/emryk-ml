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

**Systemd services enabled:** `tailscaled`, `cockpit.socket`, `bootc-fetch-apply-updates.timer`. The **rootless** per-user `podman.socket` is enabled globally (every user gets `/run/user/$UID/podman/podman.sock` automatically); the rootful system `podman.socket` is deliberately disabled — see "Containers" below.

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
| `:latest-private-ml` | `:latest` plus [Mullvad VPN](https://mullvad.net/) daemon preconfigured. Built manually on demand. |

Switch between variants with `bootc switch`; rollback to the previous deployment with `sudo bootc rollback`. `/var` and `/home` are preserved across switches.

### `:latest-private-ml` first-run

**Mullvad.** The `mullvad-daemon` service starts at boot but the system has no account credentials. Log in once with:

```bash
mullvad account login <YOUR-ACCOUNT-NUMBER>
mullvad connect
```

Or use the Mullvad GUI app, also installed.

**Unsloth Studio.** No longer preinstalled. The rootful auto-launching Quadlet that earlier builds shipped (root container, moving `:latest` tag, unauthenticated loopback bind) was removed for being the wrong trade-off in a closed-by-default image. The supported replacement is the rootless recipe at [`docs/recipes/unsloth-studio.md`](./docs/recipes/unsloth-studio.md) — a `podman run` under your user with CDI GPU passthrough.

## Remote management

Cockpit (browser-based system management) is installed and enabled on every build, but is **only reachable over Tailscale** — never over the LAN or the open internet.

Mechanism — the image declares its perimeter explicitly:

| Interface | Zone | What's reachable |
|---|---|---|
| ethernet / wifi (untrusted) | `public` (default) | `ssh` only (key-only, no password, no root — see SSH hardening below) + `dhcpv6-client`. Cockpit, mDNS, Samba, and all high ports are closed. |
| `tailscale0` (your trust boundary) | `tailscale` (`target=ACCEPT`) | Everything. Full operator access — Cockpit, ad-hoc HTTP servers, anything you bind. |
| `lo` (loopback) | unfiltered | Local apps unaffected. |

The default zone is **`public`**, not Fedora's stock `FedoraWorkstation` — the latter is permissive for desktop use and allows TCP/UDP 1025–65535 wide open, which is inappropriate for a workstation that may sit on a hostile LAN or a public IP.

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

## Containers

Container workloads run **rootless** by default. The rootless `podman.socket` is enabled globally, so every user automatically gets a Docker-compatible API socket at `/run/user/$UID/podman/podman.sock` — scoped to that user's own privileges, with no path to root. `podman`, `podman-compose`, `distrobox`, and the `docker` CLI (via `podman-docker`) all work out of the box.

For applications that connect to the Docker socket via the Docker SDK, point them at the rootless socket:

```bash
export DOCKER_HOST=unix:///run/user/$UID/podman/podman.sock
```

The rootful system socket (`/run/podman/podman.sock`, owned by root) is **deliberately disabled** — it is the classic local-root-escalation primitive (mount `/` into a privileged container, you're root). If a specific workflow truly needs it:

```bash
sudo systemctl enable --now podman.socket
```

…and reconsider whether you actually want that. There is almost always a rootless equivalent.

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

### Provenance and SBOM

Every published image also ships two attestations from GitHub Actions, signed via Sigstore (Fulcio + Rekor) with the workflow's short-lived OIDC token — no long-lived secret involved:

1. **SLSA build provenance** — cryptographically proves the image was built from this repo, at a specific commit, by this workflow.
2. **CycloneDX SBOM** — a complete machine-readable list of every package in the image, generated by [syft](https://github.com/anchore/syft) directly from the published artifact.

Both attestations are pushed to the registry as OCI referrers, so you can verify them with the GitHub CLI without trusting our key:

```bash
# Build provenance
gh attestation verify \
    oci://ghcr.io/rhuze-emryk/emryk-ml:latest \
    --repo rhuze-emryk/emryk-ml

# SBOM (CycloneDX)
gh attestation verify \
    oci://ghcr.io/rhuze-emryk/emryk-ml:latest \
    --repo rhuze-emryk/emryk-ml \
    --predicate-type https://cyclonedx.org/bom

# Download the raw SBOM
gh attestation download \
    oci://ghcr.io/rhuze-emryk/emryk-ml:latest \
    --repo rhuze-emryk/emryk-ml \
    --predicate-type https://cyclonedx.org/bom
```

These attestations are independent of the cosign signature — three different trust signals that any one of which can be verified without trusting the other two.

Disk-image artifacts produced by `build-disk.yml` (qcow2, anaconda-iso) also ship SLSA build provenance, signed via the same Sigstore-OIDC path (no long-lived key). If you received a disk image out of band, verify it before booting:

```bash
gh attestation verify path/to/disk.qcow2 --owner rhuze-emryk
```

Disk images do not currently carry a separate SBOM attestation — their RPM contents are inherited from the already-attested container image used as the bib source.

## Tags

| Tag | Description |
|---|---|
| `latest` | Current tested release |
| `YYYYMMDD` | Date-stamped build |
| `latest.YYYYMMDD` | Same build, aliased |
| `latest-private-ml` | `latest` + Mullvad VPN (manual dispatch) |
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
build_files/private-ml-install.sh   Mullvad + NVIDIA container toolkit
.github/workflows/
  build.yml                         Build, push to GHCR, sign with cosign
  build-private-ml.yml              Manual dispatch: build :latest-private-ml
  build-disk.yml                    Disk image builds (qcow2, raw, iso)
cosign.pub                          Public signing key
renovate.json                       Renovate config: keeps action SHAs, base-image digests, and tool versions current
SECURITY.md / SECURITY-TODO.md      Public security policy / private hardening backlog
KEY-POLICY.md                       Signing-key lifecycle (rotation, access, incident response)
```

## What this image is not

- Not a hobbyist image. Customizability is for the maintainer, not the user.
- Not a gaming image. See [Bazzite](https://bazzite.gg/) for that.
- Not a general-purpose desktop. Packages are chosen for ML/cloud workstation use.
- Not GNOME. KDE only.
