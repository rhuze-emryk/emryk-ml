# Security TODO

Hardening backlog for the `emryk-ml` base image and its build pipeline.
Items are ordered by real-world risk reduction, not effort.

This is a working document — strike items as they are completed, and add
new ones when threat-model assumptions change.

---

## High priority — real attack surface or supply-chain exposure

- [x] **1. Pin upstream base images by digest, not tag.** _(2026-05-22)_
  `kinoite-main` and `akmods-nvidia-open` are now pinned `tag@sha256:…` in
  both `Containerfile` and `Containerfile.private-ml`. Bumps are manual until
  renovate (item 14) is wired up.

- [x] **2. Enforce cosign verification on `bootc switch` / pulls.** _(2026-05-22)_
  Shipped via `build.sh`: `/etc/containers/policy.json` requires
  `sigstoreSigned` for `ghcr.io/rhuze-emryk` (default policy stays
  `insecureAcceptAnything` so Flathub/docker.io/ublue still work).
  `/etc/containers/registries.d/rhuze-emryk.yaml` uses
  `use-sigstore-attachments: true` so the legacy `sha256-X.sig` sibling
  tag format that cosign writes is discovered. Validated locally with
  `skopeo copy`: real key allows the pull, wrong key rejected with an
  ASN.1 signature error. Recovery if misconfigured: `bootc rollback` to
  pre-policy deployment.

- [x] **3. Add vulnerability scanning to the build workflow.** _(2026-05-22)_
  Grype scan added to both `build.yml` and `build-private-ml.yml`, runs on
  every build (PRs included) and posts a table to the workflow job summary.
  Report-only — does not fail the build. Flip to `--fail-on critical` once
  a triage process is in place.

- [x] **4. Cockpit reachable over Tailscale only.** _(2026-05-22)_
  Implemented via firewalld rather than interface-binding (binding to a
  dynamic tailnet IP at boot is fragile). Fedora's default `public` zone
  does not allow port 9090, so ethernet/wifi exposure is already closed.
  Additionally ships `/etc/firewalld/zones/tailscale.xml` (`target=ACCEPT`,
  interface `tailscale0`) so the operator has full management access over
  the tailnet immediately when tailscaled brings up the interface. Modern
  tailscaled reuses an existing zone of this name. README documents the
  access pattern.

- [x] **5. Harden SSH defaults in the image.** _(2026-05-22)_
  `/etc/ssh/sshd_config.d/10-emryk.conf` shipped via `build.sh` enforcing
  `PermitRootLogin no`, `PasswordAuthentication no`,
  `KbdInteractiveAuthentication no`, `PermitEmptyPasswords no`.

- [x] **6. Vendor the `tailscale.repo` file.** _(2026-05-22)_
  Checked in at `build_files/tailscale.repo`; `build.sh` now `cp`s it into
  `/etc/yum.repos.d/` instead of `curl`-piping from the CDN at build time.
  Follow-up worth considering: also vendor the GPG public key referenced by
  `gpgkey=` so the import path is fully offline.

## Medium priority — hardening and defense in depth

- [x] **7. Enable `bootc-fetch-apply-updates.timer` (fetch-only).** _(2026-05-22)_
  Timer enabled in `build.sh`. Service overridden via drop-in
  `/etc/systemd/system/bootc-fetch-apply-updates.service.d/10-emryk.conf`
  to drop `--apply`, so updates download and stage silently every ~8h but
  never auto-reboot — preserving long-running training jobs. README
  documents the cadence, opt-out, and rollback story.

- [ ] **8. SLSA build provenance + SBOM in CI.**
  Add `actions/attest-build-provenance` and a CycloneDX/SPDX SBOM step.
  Commercial customers will ask for both.

- [ ] **9. Explicit firewalld zone config.**
  Don't inherit Kinoite defaults — declare them. Public zone deny-all
  except SSH (when applicable) and trust the Tailscale interface.

- [x] **10. Pin every GitHub Action by SHA.** _(2026-05-22)_
  Audited every `uses:` line in `build.yml`, `build-private-ml.yml`,
  `build-disk.yml`. The only branch-tracking ref —
  `osbuild/bootc-image-builder-action@main` — is now pinned to commit
  `31d72f79…` (the action has no useful tagged releases). All other
  pre-existing SHA pins were verified against their claimed tags via
  `git ls-remote --tags` (no drift). `ublue-os/remove-unwanted-software`
  is intentionally on two different SHAs across workflows (v9 in
  build-disk.yml, post-v9 master in the others); both are SHA-pinned, so
  the audit goal is satisfied — Renovate (item #14) will harmonise them.

- [ ] **11. Decide policy for system `podman.socket`.**
  Currently enabled system-wide. Either document the threat model and
  restrict access via group, or disable and steer users to rootless podman.

- [ ] **12. Cosign key rotation + access policy.**
  If `SIGNING_SECRET` leaks, every prior signature becomes suspect. Define
  rotation cadence; restrict workflow access; evaluate Sigstore keyless
  signing as a longer-term move.

## Low priority — worth doing eventually

- [ ] **13. SECURITY.md documenting the threat model.**
  What this image protects against, what it doesn't, where customers must
  layer their own controls. Public-facing.

- [ ] **14. Wire renovate** properly. Workflow comments reference it but
  it isn't configured. This is the long-term answer to item #10 —
  Renovate's `pinDigests` mode will keep every action SHA current and
  open PRs as new versions ship, so the audit is continuous rather than
  point-in-time. Also covers base-image digest bumps (item #1).

- [ ] **15. SELinux audit.** Confirm enforcing, document any booleans
  required by NVIDIA-CDI / podman / ML workloads.

- [ ] **16. Flatpak auto-update timer.** Firefox-via-flatpak doesn't update
  on its own.

- [ ] **17. Audit `wheel` sudo policy.** Verify the inherited Kinoite default
  requires a password, and pin it explicitly in the image rather than
  relying on inheritance.

---

## Deliberately out of scope

These come up in generic hardening checklists but are not a fit here:

- AV/AM software on Linux endpoints — noise, no signal.
- Aggressive `sysctl` hardening on a workstation — fragile, breaks ML
  workloads (CUDA / shared memory / IPC).
- AppArmor on top of SELinux — pick one MAC framework.

## Status log

- 2026-05-22 — initial backlog created.
- 2026-05-22 — item 1 done: upstream base images digest-pinned in both Containerfiles.
- 2026-05-22 — item 3 done: Grype CVE scan added to both build workflows (report-only).
- 2026-05-22 — item 5 done: SSH hardening drop-in shipped via `build.sh`.
- 2026-05-22 — item 6 done: `tailscale.repo` vendored in `build_files/`.
- 2026-05-22 — item 4 scope clarified: Cockpit is Tailscale-only by design.
- 2026-05-22 — item 2 done: cosign verification enforced on pulls from `ghcr.io/rhuze-emryk` via shipped policy.json + registries.d + key.
- 2026-05-22 — variant pin in `Containerfile.private-ml` bumped to the post-cosign base digest so the variant inherits the policy.
- 2026-05-22 — item 4 done: dedicated `tailscale` firewalld zone shipped; Cockpit reachable over tailnet only.
- 2026-05-22 — item 7 done: `bootc-fetch-apply-updates.timer` enabled with `--apply` stripped via drop-in (fetch+stage only, never auto-reboot).
- 2026-05-22 — item 10 done: pinned `bootc-image-builder-action@main` → SHA; spot-verified all pre-existing pins via `git ls-remote`.
