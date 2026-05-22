# Security Policy

`emryk-ml` is the public Fedora bootc image foundation for the [Emryk Workstation](https://emryk.com) — a managed ML cloud workstation product. This document describes what the image protects against, what it does not, and how to report a security issue.

## Supported versions

The image is shipped as an immutable, bootc-managed deployment. Security fixes land via `latest` and `latest-private-ml`; older date-stamped builds are not back-supported.

| Tag | Supported |
|---|---|
| `:latest` | ✅ Yes — current tested release |
| `:latest-private-ml` | ✅ Yes — `:latest` + Mullvad + Unsloth Studio |
| `:latest.YYYYMMDD` / `:YYYYMMDD` | ⚠️ Date-stamped snapshots; not back-supported once a newer `:latest` exists |
| Older releases | ❌ Not supported — use `bootc upgrade` to roll forward |

The `bootc-fetch-apply-updates.timer` enabled in the image fetches updates roughly every 8 hours and stages them for the next user-initiated reboot. Customers running the image without disabling this timer pick up published fixes within ~24h after their next reboot.

## Threat model — what this image protects against

| Threat | Mitigation | Mechanism |
|---|---|---|
| Malicious image substitution (registry tampering, MITM, supply-chain compromise of GHCR) | All images from `ghcr.io/rhuze-emryk` are cosign-signed; installed hosts verify the signature on every pull. SLSA build provenance and CycloneDX SBOM are also attached as Sigstore-signed OCI referrers for independent verification | `/etc/containers/policy.json` + `/etc/pki/containers/rhuze-emryk.pub`; `gh attestation verify` for provenance/SBOM |
| Upstream base-image silent rewrite (`:latest` tag pointing at a new manifest) | Base images are pinned by digest, not tag | `Containerfile`, `Containerfile.private-ml` |
| Wide LAN / internet exposure of management plane | Default firewall zone restricts ingress to SSH only; Cockpit and other ports are reachable only over Tailscale | `/etc/firewalld/zones/public.xml` and `tailscale.xml` |
| Unauthenticated SSH access (password brute force, root login) | Key-only authentication, no root login, no keyboard-interactive | `/etc/ssh/sshd_config.d/10-emryk.conf` |
| Local privilege escalation via container API | Rootful `podman.socket` is disabled; rootless per-user socket enabled by default — scoped to the user's own privileges, with no path to root | `build_files/build.sh` |
| Unattended reboots killing long-running workloads | Auto-update timer fetches and stages updates only; never reboots automatically | `bootc-fetch-apply-updates.service.d/10-emryk.conf` |
| CVEs in installed packages | Every CI build runs a Grype scan against the just-built image; results posted to the workflow job summary | `.github/workflows/build.yml`, `build-private-ml.yml` |
| CI supply-chain compromise (moving-tag GitHub Actions, untrusted dependencies pulled at build time) | Every action and base image is SHA/digest-pinned; `tailscale.repo` is vendored; Renovate opens PRs to keep pins current so the audit is continuous, not point-in-time | `.github/workflows/*.yml`, `build_files/tailscale.repo`, `renovate.json` |
| Signing-key compromise | Annual scheduled rotation + on-incident rotation, with a graceful transition window | [KEY-POLICY.md](./KEY-POLICY.md) |
| Process escape via kernel vulnerability or misbehaving container | SELinux **enforcing**, targeted policy; explicitly declared in the image | `/etc/selinux/config` |
| Unpatched system flatpaks (Firefox, etc.) sitting between user actions | `flatpak-system-update.timer` enabled in the image; auto-updates daily | `build_files/build.sh` |

## Threat model — what this image does NOT protect against

Below are deliberately out of scope for the base image. Customers running production-sensitive workloads must layer additional controls.

- **Per-workload isolation of ML jobs.** A malicious training script, model weight, or notebook can read everything the user can read and write everything the user can write. If you run untrusted code, run it in a constrained Distrobox / podman container with explicit volume mounts only — not as your interactive user.
- **Full-disk encryption.** LUKS is the installer's decision, not the image's. We do not currently ship an installer that enforces LUKS-on-root. If you require encryption at rest, configure it at install time and verify after.
- **Data-at-rest secret management.** Secrets in `/home`, `/var`, or distrobox container storage are protected only by the filesystem permissions you give them and (if you chose it) by LUKS. The image provides no key-management or vaulting layer.
- **Tailnet-side trust.** The `tailscale` firewalld zone is `target=ACCEPT` — every machine on your tailnet is treated as fully trusted for this host's management plane. If you share a tailnet with untrusted peers, this assumption breaks.
- **GPU compute-side attacks.** Vulnerabilities in the NVIDIA driver stack or in GPU compute isolation (between processes sharing a GPU) are not mitigated here. Track upstream NVIDIA advisories.
- **Side-channel attacks on shared hosting infrastructure.** If this image runs on hardware shared with untrusted tenants, microarchitectural side channels (Spectre-family, etc.) are not addressed in this image.
- **Anti-virus / anti-malware on Linux endpoints.** Intentionally out of scope — see `SECURITY-TODO.md` §"Deliberately out of scope". Not a signal-to-noise win on a workstation Linux platform.
- **Customer-supplied software.** This image ships a base + curated tooling. Anything installed via `dnf`, distrobox, flatpak, or container pull after first boot is the customer's responsibility — including the `unsloth/unsloth` image referenced by `:latest-private-ml`.

## Reporting a vulnerability

We accept reports through two channels — please use whichever is more convenient. Either way, **do not** open a public GitHub issue for security-sensitive findings.

1. **GitHub Private Vulnerability Reporting** — visit https://github.com/rhuze-emryk/emryk-ml/security/advisories/new and file a private advisory. This is the preferred channel for researchers with GitHub accounts.
2. **Email** — `security@emryk.com`. PGP key fingerprint will be published here if and when one exists; until then, treat email as in-band and avoid exfil-style proof-of-concept content in the initial report.

When reporting, please include:

- A description of the issue and its impact.
- Steps to reproduce, or a proof-of-concept.
- The image tag and digest you observed the issue on (`bootc status` shows both).
- Whether you've disclosed this elsewhere.

## Triage and remediation SLAs

These are commitments, not guarantees — best-effort with the caveats below.

| Severity | Triage acknowledgement | Fix or mitigation shipped |
|---|---|---|
| **Critical** (remote code execution, signature bypass, privilege escalation from network) | ≤ 7 days | ≤ 90 days |
| **High** (privilege escalation requiring local foothold, persistent data exposure) | ≤ 7 days | ≤ 90 days |
| **Medium / Low** | ≤ 14 days | Best effort, next regular release |

Caveats:

- "Shipped" means a build is published to GHCR and the auto-update timer will deliver it. Customer hosts pull updates within ~24h of publication and apply on next reboot.
- Issues in upstream components (Fedora packages, NVIDIA driver, Universal Blue base) follow their respective vendor timelines. We update our base pin to pick up upstream fixes as soon as they're available.

## Coordinated disclosure

We follow coordinated-disclosure norms:

- **90-day window** from the date of acknowledged triage to public disclosure, with the timeline extendable by mutual agreement between Emryk and the reporter.
- The 90-day clock continues to run even if a fix has not yet shipped. If a fix is not ready by day 90, we coordinate on disclosure language with the reporter.
- We will publicly credit reporters who request it. Reporters who prefer anonymity will be credited as "an external researcher" or per their preferred handle.
- If a vulnerability is being actively exploited in the wild, the 90-day clock collapses — we accelerate disclosure and ship mitigations as fast as possible.

## Supply chain trust

Three independent trust signals are attached to every published image:

1. **Cosign signature** — proves the image was signed by our long-lived key. Required for `bootc` pulls to succeed (`/etc/containers/policy.json` enforces this on installed hosts). Key lifecycle is governed by [KEY-POLICY.md](./KEY-POLICY.md): annual scheduled rotation + on-incident, graceful transition procedure, and a roadmap to Sigstore keyless signing.
2. **SLSA build provenance** — Sigstore-signed (via the workflow's short-lived OIDC token, no secret to leak) attestation that the image was built from this repo at a specific commit, by a specific workflow. Verifiable with `gh attestation verify oci://... --repo rhuze-emryk/emryk-ml`.
3. **CycloneDX SBOM** — complete package manifest generated by [syft](https://github.com/anchore/syft) from the published artifact, attached as a Sigstore-signed attestation. Verifiable with the same `gh attestation verify` command plus `--predicate-type https://cyclonedx.org/bom`.

Any one of these signals can be verified independently of the others. See the "Provenance and SBOM" section of [README.md](./README.md) for the verification recipes.
