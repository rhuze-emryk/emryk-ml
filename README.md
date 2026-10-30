# Emryk ML

[![Build status](https://github.com/rhuze-emryk/emryk-ml/actions/workflows/build.yml/badge.svg)](https://github.com/rhuze-emryk/emryk-ml/actions/workflows/build.yml)

Emryk ML is a managed Fedora Kinoite [bootc](https://github.com/bootc-dev/bootc)
image for ML workstations. It publishes two AMD64 variants each Saturday, or on
an explicitly approved manual release:

| Image | Intended hardware | Variant-specific payload |
|---|---|---|
| `ghcr.io/rhuze-emryk/emryk-ml` | NVIDIA workstation | NVIDIA open kernel modules, container toolkit, boot-time CDI generation, and a nouveau blacklist |
| `ghcr.io/rhuze-emryk/emryk-ml-intel` | Intel iGPU workstation or laptop | Mesa/base graphics only; no NVIDIA packages, module metadata, toolkit, CDI unit, or nouveau blacklist |

Both variants include KDE Plasma, Tailscale, Cockpit, Podman, Distrobox, common
developer tools, signature policy, SELinux configuration, and the same update
behavior. The published image names and moving `:latest` tags are stable.

## Install or switch

From an AMD64 bootc system, select exactly one variant:

```bash
sudo bootc switch ghcr.io/rhuze-emryk/emryk-ml:latest
sudo systemctl reboot
```

```bash
sudo bootc switch ghcr.io/rhuze-emryk/emryk-ml-intel:latest
sudo systemctl reboot
```

From the first Emryk boot onward, every OS update must carry a valid Emryk
signature or it is refused. The shipped `/etc/containers/policy.json` requires
it for everything under `ghcr.io/rhuze-emryk`, and `bootc upgrade` applies that
policy whatever the deployment's origin says. `rpm-ostree status` may show
`ostree-unverified-registry:` after a plain `switch`; that prefix only means
bootc skips one extra pre-flight check on the policy file, not that signatures
are ignored. Each release is tested for this: the boot gate confirms the
installed host refuses the not-yet-signed release candidate.

The first `switch` itself cannot be verified by the host: the system you
switch from does not have the Emryk key yet. To close that gap, verify the
digest with `cosign` first (see [Verify published artifacts](#verify-published-artifacts))
and switch to that exact digest, `ghcr.io/rhuze-emryk/emryk-ml@sha256:…`. After
the first boot, follow releases again with
`sudo bootc switch --enforce-container-sigpolicy ghcr.io/rhuze-emryk/emryk-ml:latest`.
That switch is verified, because the host now has the key.

If `/etc/containers/policy.json` has been modified locally, it masks the shipped
policy; compare it with `/usr/etc/containers/policy.json`.

`bootc-fetch-apply-updates.timer` periodically fetches and stages a newer
signed deployment. It does not initiate a reboot. A login message announces a
staged deployment; the operator chooses when to reboot. `bootc rollback`
selects the previous deployment while preserving state under `/var` and
`/home`.

## Runtime behavior

- SSH is explicitly enabled and configured for public-key authentication;
  root, password, empty-password, and keyboard-interactive SSH login are
  disabled by the shipped drop-in.
- Firewalld uses a restrictive `public` zone that declares only
  `dhcpv6-client`. `tailscale0` is assigned to a separate accepting zone for
  SSH, Cockpit, and operator-chosen services. Existing network-profile or
  administrator changes can alter that effective perimeter.
- The rootless per-user Podman socket is enabled globally. The system rootful
  socket is not enabled by this image. Rootless containers reduce daemon and
  socket privilege exposure; they are not a boundary against kernel or
  container-runtime vulnerabilities.
- SELinux is configured for enforcing mode and asserted by the release VM.
  Administrators can still change runtime or persistent policy after install.
- Firefox is installed from Flathub by an enabled network-dependent first-boot
  unit. Release VMs validate the unit but mask it for the smoke boot so an
  external Flathub outage cannot block publication.
- Cockpit and Tailscale are enabled. Tailscale is a deliberate management-plane
  dependency; Headscale can provide a self-hosted coordination server.

The NVIDIA image regenerates `/etc/cdi/nvidia.yaml` through the upstream
`nvidia-cdi-refresh.service` (shipped by `nvidia-container-toolkit`, enabled
by the akmods install script). A typical rootless workload is:

```bash
podman run --rm --device nvidia.com/gpu=all \
  docker.io/nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi
```

On a machine without a usable NVIDIA GPU the image's `nvidia-cdi-refresh` and
`nvidia-persistenced` units fail and give up after five attempts within two
minutes (Emryk drop-ins), so `multi-user.target` still becomes active; the
upstream 10-second window never fills on slow hardware and left the target
pending forever.

Hosted CI validates module metadata, toolkit presence, and the CDI unit, but
has no physical GPU. Hardware validation remains a release-assurance gap; see
[the NVIDIA hardware-canary runbook](docs/hardware-canary.md).

## Verify published artifacts

The container image signature uses the active Emryk cosign key committed as
[`cosign.pub`](cosign.pub). These commands are live-tested with the repository's
pinned cosign v3.0.6 release and force discovery of the legacy key attachment:

```bash
cosign verify \
  --key https://raw.githubusercontent.com/rhuze-emryk/emryk-ml/main/cosign.pub \
  --new-bundle-format=false \
  ghcr.io/rhuze-emryk/emryk-ml:latest
```

```bash
cosign verify \
  --key https://raw.githubusercontent.com/rhuze-emryk/emryk-ml/main/cosign.pub \
  --new-bundle-format=false \
  ghcr.io/rhuze-emryk/emryk-ml-intel:latest
```

Installed hosts use `/etc/containers/policy.json` to require a matching
signature for pulls under `ghcr.io/rhuze-emryk`. OS updates enforce it
regardless of whether the deployment origin reads `ostree-image-signed` or
`ostree-unverified-registry` (see [Install or switch](#install-or-switch)). The recovery signer is not an
operational host trust root until the offline custodian supplies and commits
`recovery-cosign.pub`; that bootstrap is tracked as P0 in
[SECURITY-TODO.md](SECURITY-TODO.md).

Each release exposes three complementary, independently inspectable artifacts:

| Artifact | Trust root | Scope |
|---|---|---|
| Container signature | Committed Emryk active public key; recovery key after bootstrap | Authorizes a particular OCI manifest digest for the Emryk namespace |
| Build provenance | GitHub Actions OIDC identity, Fulcio/Rekor, and GitHub attestation verification | Binds the digest to this repository, commit, and workflow invocation |
| CycloneDX SBOM attestation | Same GitHub Actions OIDC attestation identity | RPM-database inventory plus the explicitly reviewed non-RPM helper exceptions |

Verify provenance or the SBOM for either image by substituting its OCI name:

```bash
gh attestation verify \
  oci://ghcr.io/rhuze-emryk/emryk-ml:latest \
  --repo rhuze-emryk/emryk-ml

gh attestation download \
  oci://ghcr.io/rhuze-emryk/emryk-ml:latest \
  --repo rhuze-emryk/emryk-ml \
  --predicate-type https://cyclonedx.org/bom
```

The SBOM is intentionally generated from the Fedora RPM database to stay
within hosted-runner limits. It is not a filesystem inventory. The build fails
for unowned executable payloads except the two exact reviewed helpers under
`/usr/libexec/emryk` and documented base/build-system artifacts in the payload
guard. Configuration files and other non-executable image content are outside
the RPM inventory; [SECURITY.md](SECURITY.md) defines the resulting assurance.

AMD64 QCOW2 artifacts also receive GitHub build-provenance attestations:

```bash
gh attestation verify path/to/disk.qcow2 --owner rhuze-emryk
```

## Build and test locally

Supported operations require Podman and [just](https://just.systems):

```bash
just build                  # NVIDIA container
just build-intel            # Intel container
just build-qcow2            # AMD64 QCOW2 from a published source
just rebuild-qcow2 intel    # rootful local Intel rebuild, then QCOW2
just local-smoke            # repository policy tests
just check                  # syntax, ShellCheck, policy, and optional installed linters
just format                 # shfmt + Just formatting
just clean                  # only QCOW2/BIB generated output
```

Only the operations listed above are supported.

## Maintainer sources of truth

- [SECURITY.md](SECURITY.md): binding threat model, assurances, and limitations.
- [UPDATING.md](UPDATING.md): release, verification, and recovery operations.
- [KEY-POLICY.md](KEY-POLICY.md): active/recovery signer lifecycle and fleet
  evidence requirements.
- [SECURITY-TODO.md](SECURITY-TODO.md): short active risk register.
- [ONBOARDING.md](ONBOARDING.md): non-authoritative product guidance linking
  back to the documents above.
