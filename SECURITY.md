# Security policy

This document is the binding description of Emryk ML's security model. Product
summaries and onboarding material defer to it when wording differs.

## Supported releases

The current `:latest` deployment of each published image is supported:

- `ghcr.io/rhuze-emryk/emryk-ml:latest` (NVIDIA)
- `ghcr.io/rhuze-emryk/emryk-ml-intel:latest` (Intel)

Date tags are immutable snapshots, not maintained release branches. Hosts must
reboot into a staged deployment before its fixes become active.

## Trust model

Publication is allowed only on the weekly schedule or a default-branch manual
dispatch. Both variants are built and scanned, pushed under a staging tag, and
resolved to immutable digests. Each digest must then boot under OVMF in a
QEMU VM (software emulation — GitHub-hosted runners expose no KVM) and pass
the assertions in `tests/boot-smoke-guest.sh`. Only then does the protected
`production-signing` environment request approval.

After approval, the workflow signs the staged digest with the encrypted active
key, verifies that signature against the committed active public key, promotes
the same digest to release tags, and attaches provenance and SBOM attestations.
Tag promotion uses digest-preserving registry copies. Ordinary pushes to
`main`, pull requests, and unapproved runs do not move release tags.

The release provides three complementary, independently inspectable artifacts:

1. The Emryk cosign signature trusts the active public key in this repository.
   Installed hosts enforce it through one `sigstoreSigned` policy requirement
   whose `keyPaths` are alternatives. The offline recovery public key becomes a
   second permanent alternative only after its explicit bootstrap transition.
2. Build provenance trusts the GitHub Actions OIDC workload identity and the
   Sigstore/GitHub attestation verification path. It identifies the repository,
   workflow, commit, and subject digest; it does not make the workflow or source
   code benign.
3. The CycloneDX SBOM attestation uses the same workload identity and inventories
   the image's RPM database. It is not a complete filesystem or language-package
   inventory.

The signing key and GitHub OIDC identity are different trust roots. Inspecting
all artifacts provides more evidence than inspecting one, but compromise of the
source, authorized workflow, or dependencies can still produce internally
consistent malicious artifacts.

## Implemented controls and bounds

| Area | Implemented control | Important bound |
|---|---|---|
| Registry substitution | Digest-addressed cosign signing and host-side `sigstoreSigned` verification for the Emryk namespace | Hosts installed before recovery-key bootstrap require manual recovery if the active signer is compromised |
| Base images and CI dependencies | Container bases, BIB, and Actions are digest/full-SHA pinned; Renovate proposes updates | A reviewed pin can still identify vulnerable or malicious upstream content |
| Tailscale packages | Repository configuration and OpenPGP key are vendored; DNF uses a local `file://` key; weekly drift checks compare both | The build still downloads RPMs and metadata from Tailscale's HTTPS repository; its signing-key custody remains upstream trust |
| Vulnerability gate | Grype blocks unwaived critical findings in the RPM-derived SBOM; waivers are reviewed and dated | Severity data and distro matching can be incomplete; non-RPM/configuration defects are not covered by this scan |
| Executable payload | Build guard rejects unowned executable files except exact reviewed paths and documented generated base artifacts | `/usr/libexec/emryk/install-flatpaks.sh` and `update-nudge.sh` are source-controlled exceptions; configuration outside scanned payload directories is not an RPM component |
| Boot assurance | Both exact staged digests must reach multi-user console login and pass policy, unit, firewall, SSH, SELinux, and variant assertions in a hosted VM | Hosted runners provide no physical NVIDIA device; runtime driver/GPU behavior needs the hardware canary |
| SSH | Shipped effective configuration disables root, password, empty-password, and keyboard-interactive login | Console access, administrator drop-ins, cloud provisioning, or later local changes can alter access |
| Firewall | Shipped `public` zone omits SSH and Cockpit; `tailscale0` is assigned to an accepting zone | Existing NetworkManager profiles and administrator changes may select other zones; the Tailscale zone intentionally exposes locally bound services to tailnet peers |
| SELinux | Persistent configuration requests enforcing mode and VM smoke asserts `getenforce` | Local administrators and kernel command-line changes can disable or relax enforcement |
| Containers | Rootless user socket enabled; rootful system socket not enabled | Rootless operation does not eliminate kernel, runtime, user-namespace, device, or user-account privilege risks |
| Updates | Timer fetches and stages verified deployments without rebooting | A compromised trusted signer or authorized build path can publish a signed bad update; delayed operator reboot delays fixes |
| OpenCode | Slash commands require trusted commenter and PR author associations, a same-repository PR, and immutable head SHA before checkout/API-key exposure | OpenCode executes repository content and is not a security sandbox; maintainer authorization is the trust boundary |

## Variant boundary

The shared build layer contains no NVIDIA package or module policy. The NVIDIA
stage alone installs the akmods payload and nouveau blacklist. The Intel smoke
leg fails if NVIDIA module metadata, toolkit/driver packages, or the blacklist
are present. The NVIDIA leg checks kernel/module version coupling at build time
and module/toolkit/CDI metadata at boot. Physical checks are defined in
[docs/hardware-canary.md](docs/hardware-canary.md).

## Signing compromise and recovery

The intended steady-state trust set contains the active signer and a permanently
trusted offline recovery signer in one `keyPaths` array. Multiple separate
policy requirements are cumulative and therefore must not be used to express
alternatives. Planned rotation requires observed successful boots of the
transition image across the managed fleet; elapsed time or staging status is
not evidence. Incident recovery uses only the offline recovery signer to ship
an image that removes the compromised active key and introduces a fresh one.

The recovery public key is not yet committed, so this steady state is not yet
in force. See [KEY-POLICY.md](KEY-POLICY.md) and the P0 entry in
[SECURITY-TODO.md](SECURITY-TODO.md). Private keys and passphrases must never be
placed in the repository, workspace, GitHub artifacts, or issue content.

## Vulnerability reporting

Report suspected vulnerabilities through GitHub Private Vulnerability
Reporting for this repository or email `security@emryk.com`. Include affected
digests, reproduction details, and impact when possible; do not include private
keys, credentials, or customer data.

Emryk aims to acknowledge critical/high-impact reports within seven days and
coordinate a fix and disclosure according to impact. That is an operational
target, not a warranty. Public disclosure before a fix should be coordinated
when active exploitation would put users at risk.
