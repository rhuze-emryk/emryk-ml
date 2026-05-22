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

- [ ] **2. Enforce cosign verification on `bootc switch` / pulls.**
  Images are signed but installed systems do not require a valid signature
  by default. Ship `/etc/containers/policy.json` + `registries.d/` config
  so any pull from `ghcr.io/rhuze-emryk/` must verify against `cosign.pub`.
  Without this, a compromised GHCR token lets an attacker push a malicious
  `:latest` and every user upgrade silently accepts it.

- [x] **3. Add vulnerability scanning to the build workflow.** _(2026-05-22)_
  Grype scan added to both `build.yml` and `build-private-ml.yml`, runs on
  every build (PRs included) and posts a table to the workflow job summary.
  Report-only — does not fail the build. Flip to `--fail-on critical` once
  a triage process is in place.

- [ ] **4. Cockpit listens on all interfaces by default.**
  For a cloud workstation that may have a public IP, this is exposed admin
  UI. Either bind to localhost (require Tailscale / SSH-tunnel access) or
  document that customers must firewall port 9090.

- [ ] **5. Harden SSH defaults in the image.**
  Ship `/etc/ssh/sshd_config.d/10-emryk.conf` enforcing:
  - `PermitRootLogin no`
  - `PasswordAuthentication no`
  - `KbdInteractiveAuthentication no`
  Public-IP cloud workstations get scanned within minutes of boot.

- [ ] **6. Vendor the `tailscale.repo` file.**
  Currently `curl`-piped from `pkgs.tailscale.com` at build time. Packages
  are GPG-checked, but a CDN-level compromise could swap baseurl/gpgkey
  before the build sees it. Check the file into the repo and `cp` it into
  place during build.

## Medium priority — hardening and defense in depth

- [ ] **7. Enable `bootc-fetch-apply-updates.timer`.**
  Security fixes only matter if they reach users. Enable the timer so
  pushed updates are pulled automatically. Document the rollback story.

- [ ] **8. SLSA build provenance + SBOM in CI.**
  Add `actions/attest-build-provenance` and a CycloneDX/SPDX SBOM step.
  Commercial customers will ask for both.

- [ ] **9. Explicit firewalld zone config.**
  Don't inherit Kinoite defaults — declare them. Public zone deny-all
  except SSH (when applicable) and trust the Tailscale interface.

- [ ] **10. Pin every GitHub Action by SHA.**
  Audit all workflows. A compromised action with a moving tag can exfil
  `SIGNING_SECRET`.

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
  it isn't configured.

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
