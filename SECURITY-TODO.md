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

- [x] **4. Cockpit reachable over Tailscale only.** _(2026-05-22; correctly closed by item #9)_
  Initial commit shipped `/etc/firewalld/zones/tailscale.xml`
  (`target=ACCEPT`, interface `tailscale0`) — the tailnet half is correct.
  However the original status note claimed "Fedora's default `public`
  zone does not allow port 9090, so ethernet/wifi exposure is already
  closed." That was wrong: Kinoite ships `FedoraWorkstation` (not
  `public`) as the default zone, and FedoraWorkstation allows cockpit
  plus all TCP/UDP 1025–65535. Cockpit was in fact LAN-reachable on the
  initial image. The fix lands in item #9 (default zone → `public`,
  with cockpit and high ports stripped). Treat #4 as fully closed only
  after #9 ships.

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

- [x] **8. SLSA build provenance + SBOM in CI.** _(2026-05-22)_
  Both `build.yml` and `build-private-ml.yml` now generate and attest:
  - **SLSA build provenance** via `actions/attest-build-provenance@v4.1.0`
  - **CycloneDX-JSON SBOM** via `syft v1.44.0` + `actions/attest-sbom@v4.1.0`

  Attestations are signed via Sigstore using the workflow's short-lived
  OIDC token (no long-lived secret) and pushed to the registry as OCI
  referrers (`push-to-registry: true`), so customers can verify with
  `gh attestation verify` against the published artifact alone — no
  GitHub API trust needed beyond the registry. Each image now carries
  three independent trust signals: cosign signature (item #2), SLSA
  provenance, and SBOM. README and SECURITY.md document the
  verification recipes. SPDX format deferred — can add in ~10 min if a
  customer specifically asks.

- [x] **9. Explicit firewalld zone config.** _(2026-05-22)_
  Default zone switched from inherited `FedoraWorkstation` (which
  allowed cockpit + all TCP/UDP 1025–65535 wide open) to `public`,
  set in `build.sh` via `firewall-offline-cmd --set-default-zone=public`.
  `/etc/firewalld/zones/public.xml` overrides the upstream public zone
  to keep only `ssh` (key-only, see item #5) and `dhcpv6-client`;
  `mdns`, `cockpit`, and everything else are dropped. Combined with
  item #4's `tailscale` zone (`target=ACCEPT`), the perimeter is now
  explicitly declared: untrusted networks see only SSH, the tailnet
  sees everything, loopback is unfiltered.

  Upgrade gotcha: NM connection profiles created before this lands
  inherit the default zone implicitly. Existing profiles should fall
  back to `public` automatically on reboot, but `nmcli c modify <conn>
  connection.zone public` is the manual fix if not.

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

- [x] **11. Disable rootful `podman.socket`; rootless on by default.** _(2026-05-22)_
  System `podman.socket` removed from `systemctl enable` (it ran as root
  and is the classic local-root-escalation primitive). Rootless
  per-user socket enabled globally via `systemctl --global enable
  podman.socket`, so every user gets `/run/user/$UID/podman/podman.sock`
  automatically — scoped to their own privileges, no escalation path.
  Docker SDK consumers must use `DOCKER_HOST=unix:///run/user/$UID/podman/podman.sock`
  rather than the legacy `/var/run/docker.sock` path. README documents
  the change and the recovery (`sudo systemctl enable --now podman.socket`)
  for users who specifically need rootful.

- [x] **12. Cosign key rotation + access policy.** _(2026-05-22)_
  Documented in [KEY-POLICY.md](./KEY-POLICY.md): threat model, access
  policy (current state + target with GH Environment protection),
  scheduled rotation cadence (**annual + on-incident**), the graceful
  rotation procedure (transition image that trusts old+new keys; this
  works without code change because the existing `containers-policy.json`
  policy array already accepts multiple sigstoreSigned entries),
  incident-response runbook, and the keyless-signing roadmap
  (**evaluate by EOY 2026, migrate by EOY 2027**).

  The GitHub Environment runbook in KEY-POLICY.md is a one-time UI task
  the maintainer must do on github.com (`gh` is not available on the
  workstation that drives this repo) — does not block closing this
  item, since the policy itself is now defined.

## Low priority — worth doing eventually

- [x] **13. SECURITY.md documenting the threat model.** _(2026-05-22)_
  Shipped [SECURITY.md](./SECURITY.md) at repo root: supported versions,
  what the image protects against (with mechanism references), what it
  deliberately does NOT (where customers layer their own controls),
  vulnerability reporting via `security@emryk.com` + GitHub Private
  Vulnerability Reporting (enabled on the repo at this commit), triage
  SLAs (≤7d critical/high triage, ≤90d fix), and a 90-day coordinated-
  disclosure window. Cross-links KEY-POLICY.md for the supply-chain
  story.

  Follow-up the maintainer must do outside this commit: set up
  `security@emryk.com` as an alias to the real mailbox.

- [x] **14. Wire Renovate.** _(2026-05-22)_
  Shipped `renovate.json` at repo root configuring Mend Renovate Bot
  (the OSS-free GitHub App):
  - `pinDigests: true` for GitHub Actions (continuous answer to #10)
    and Docker base images (continuous answer to #1).
  - Custom managers track `GRYPE_VERSION` (#3) and `SYFT_VERSION` (#8)
    env vars against anchore/grype and anchore/syft GitHub releases.
  - Weekly Monday-morning schedule (America/New_York) to batch updates.
  - No auto-merge — every PR reviewed (matches [[project-hardening-philosophy]]:
    closed by default + explicit opt-in).

  Activation is a one-time UI step the maintainer must do:
  1. Visit https://github.com/apps/renovate
  2. Install on `rhuze-emryk/emryk-ml`
  3. The first PR Renovate opens will be a "Configure Renovate" onboarding
     PR that validates our `renovate.json`. Merge it.

  Until the install is done, `renovate.json` is inert. The config itself
  is committed and reviewed, which is the part this item was tracking.

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
- 2026-05-22 — item 11 done: rootful `podman.socket` disabled; rootless socket enabled globally per-user. Docker SDK consumers must move to `$DOCKER_HOST` pointing at rootless.
- 2026-05-22 — item 9 done: default zone → `public`, override drops mdns/cockpit/high-ports; corrects item #4's wrong-assumption status (default was FedoraWorkstation, not public; cockpit was in fact LAN-reachable until this commit).
- 2026-05-22 — item 12 done: `KEY-POLICY.md` shipped with rotation cadence (annual + on-incident), graceful procedure, incident runbook, GH Environment protection runbook, and keyless-signing roadmap.
- 2026-05-22 — annual signing-key rotation scheduled as remote routine `trig_018BR9ZVeAzvocpPtPQQn4kR`, fires 2027-05-22T13:00:00Z (09:00 ET). Will open a tracking issue and hand off to maintainer; performs no cryptographic action.
- 2026-05-22 — item 13 done: `SECURITY.md` shipped (threat model, SLAs, disclosure policy); GitHub Private Vulnerability Reporting enabled on the repo via `gh api`.
- 2026-05-22 — item 8 done: SLSA build provenance + CycloneDX SBOM attestations added to both publish workflows; pushed to GHCR as OCI referrers. Three independent trust signals per image now.
- 2026-05-22 — item 14 done: `renovate.json` shipped (action SHA + base-image digest pinning, custom managers for GRYPE_VERSION/SYFT_VERSION, weekly schedule, no auto-merge). Maintainer must install the Renovate GitHub App at github.com/apps/renovate for the config to activate.
