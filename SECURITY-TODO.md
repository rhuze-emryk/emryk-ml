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

- [x] **3. Add vulnerability scanning to the build workflow.** _(2026-05-22; pivoted to SBOM-based scan 2026-05-23; payload coverage mechanically enforced 2026-05-27)_
  Grype scan back in `build.yml` + `build-private-ml.yml`, running
  per-push against the SBOM (`grype sbom:./sbom.cdx.json`) rather than
  re-cataloging the image. Fast (seconds), report-only. Initial attempt
  to scan the image directly blew past the free-runner lost-comms
  watchdog on this multi-GB Fedora bootc rootfs; nightly fallback was
  the first pivot, then SBOM-based scan let us put it back per-push.
  The SBOM-only scope (RPM-installed packages) is now enforced at build
  time by `build_files/verify-payload-rpm-owned.sh` — any non-allowlisted
  unowned file under executable-payload dirs fails the build, so the
  grype scan can't silently miss a vendor binary dropped outside dnf.
  Flip to `--fail-on critical` once a triage process is in place.

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

- [x] **18. Harden the Unsloth Studio quadlet.** _(2026-05-28 — obsoleted by removal)_
  Original concern: the variant shipped a rootful Quadlet pulling
  `docker.io/unsloth/unsloth:latest` with no digest pin, plus a polkit
  rule granting `wheel`-group silent start of the resulting root
  container. On any workstation with multiple local users (or distrobox
  tenants) every local user could drive a root-privileged container
  with full GPU access via the `127.0.0.1:8888` no-auth UI.

  Resolved by removing the Quadlet entirely (PR #11) rather than
  hardening it: the closed-by-default principle judged the convenience
  trade-off (auto-launching, polkit-greased, root-privileged container)
  wrong for an image of this shape. Unsloth Studio is now documented as
  a rootless recipe at `docs/recipes/unsloth-studio.md` (PR #12) — a
  user-scope `podman run` with CDI GPU passthrough, no rootful surface,
  no polkit rule, no preconfigured `:latest` pull. Customers who want
  the old auto-start convenience can drop a user-Quadlet under
  `~/.config/containers/systemd/` — documented in the recipe.

- [x] **19. Vendor the Mullvad + NVIDIA container-toolkit repo files.** _(2026-05-28)_
  Both files checked in under `build_files/` (PR #14). The variant
  install script and `build.sh` now `cp` from `/ctx/` instead of
  `curl`-piping from the vendor CDNs (variant patched in PR #14, base
  in PR #16). Closes the CDN-tamper window that #6 solved for Tailscale.

  Drift detection follow-up landed as `.github/workflows/vendor-drift-watch.yml`
  (PR #18): weekly fetch + diff of each vendored file vs. its upstream
  URL, opens/updates a GitHub issue if drift is detected.

  **Per-vendor gpgcheck variance** (correction to an earlier claim in
  this entry): the closing-window framing said "the gpgcheck=1 still
  verifies the actual package signature at install time." That is true
  for `mullvad.repo` and `tailscale.repo` (both `gpgcheck=1`) but
  **false** for `nvidia-container-toolkit.repo`, which mirrors upstream's
  `gpgcheck=0` — only repodata metadata is signature-checked, not the
  RPMs themselves. Closing the gap is tracked separately in #24.

- [ ] **24. Close the `gpgcheck=0` gap on vendored `nvidia-container-toolkit.repo`.**
  `build_files/nvidia-container-toolkit.repo` mirrors upstream's
  `gpgcheck=0` (only `repo_gpgcheck=1`). RPMs from this repo are
  installed without package-signature verification, so an attacker who
  serves a malicious nvidia-container-toolkit RPM via a compromised
  mirror or TLS-MITM (with a CA the build trusts) lands the package
  unchallenged. Decision needed: either (a) flip the vendored copy to
  `gpgcheck=1` — vendoring is exactly the mechanism that buys us the
  freedom to deviate from upstream; this would surface any genuinely
  unsigned package as a build-time failure — or (b) accept upstream's
  posture and amend SECURITY.md to be explicit that this repo has a
  metadata-only trust boundary.
  Closing condition: a decision documented in SECURITY.md and reflected
  in the vendored file.

## Medium priority — hardening and defense in depth

- [x] **7. Enable `bootc-fetch-apply-updates.timer` (fetch-only).** _(2026-05-22)_
  Timer enabled in `build.sh`. Service overridden via drop-in
  `/etc/systemd/system/bootc-fetch-apply-updates.service.d/10-emryk.conf`
  to drop `--apply`, so updates download and stage silently every ~8h but
  never auto-reboot — preserving long-running training jobs. README
  documents the cadence, opt-out, and rollback story.

- [x] **8. SLSA build provenance + SBOM in CI.** _(2026-05-22; SBOM scope narrowed to RPM-only 2026-05-23; disk-image provenance + RPM-payload guard 2026-05-27)_
  `build.yml` and `build-private-ml.yml` generate and attest per-push:
  - **SLSA build provenance** via `actions/attest-build-provenance@v4.1.0`
  - **CycloneDX-JSON SBOM** via `syft v1.44.0` against the image's RPM
    database (extracted via `buildah unshare mount`), then
    `actions/attest-sbom@v4.1.0`

  `build-disk.yml` also produces SLSA build provenance for each qcow2 /
  ISO file it builds (no SBOM — disk artifacts inherit RPM contents from
  the already-attested container image). The RPM-only SBOM scope is
  enforced at build time by `build_files/verify-payload-rpm-owned.sh`
  (see item 3).

  Attestations are signed via Sigstore using the workflow's short-lived
  OIDC token (no long-lived secret) and pushed to the registry as OCI
  referrers (`push-to-registry: true`), so customers can verify with
  `gh attestation verify` against the published artifact alone — no
  GitHub API trust needed beyond the registry. Each image carries
  three independent trust signals: cosign signature (item #2), SLSA
  provenance, and SBOM.

  Scope tradeoff: SBOM covers RPM-installed packages only, not
  arbitrary filesystem content. Audited at 2026-05-23 that every
  third-party payload in `build_files/build.sh` and
  `private-ml-install.sh` is installed via `dnf` — so coverage is
  ~100% today. If a future change ever drops a binary into the image
  outside of an RPM (e.g. `curl … | tar -C /usr/local/bin`), that
  binary would be invisible to both the SBOM and the CVE scan. A
  build-time "every file under /usr/bin must be owned by an RPM"
  guard would close the gap — worth a follow-up TODO if non-RPM
  payloads ever become a temptation.

  README and SECURITY.md document the verification recipes. SPDX
  format deferred — can add in ~10 min if a customer specifically asks.

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

- [ ] **20. Flip Grype to `--fail-on critical`.**
  #3 left this as a follow-up "once a triage process is in place." The
  Grype step in both `build.yml` and `build-private-ml.yml` runs with
  `continue-on-error: true` and no `--fail-on`, so a critical CVE in
  the SBOM shows up in the job summary but does not block merge or
  publish. Define triage first (proposed default: criticals block;
  highs open a tracking issue; mediums report-only), document it in
  SECURITY.md, then flip the flag.
  Closing condition: triage process documented in SECURITY.md and the
  workflow blocks on critical CVEs.

- [ ] **25. Remove redundant `nvidia-container-toolkit` install + CDI service from base `build.sh`.**
  PR #13 added `nvidia-container-toolkit` to `build_files/build.sh`'s
  dnf list and shipped a new `/etc/systemd/system/nvidia-cdi-generate.service`
  heredoc that runs `nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml`
  at boot. **Upstream `ublue-os/akmods` `nvidia-install.sh` already does
  both** — its `NVIDIA_RPMS` array installs `nvidia-container-toolkit`,
  and `ublue-os-nvidia-addons` ships `/usr/lib/systemd/system/ublue-nvctk-cdi.service`
  enabled via preset (and explicitly via `systemctl enable` in the same
  upstream script). Result on every base boot: two oneshot services
  race to write the same `/etc/cdi/nvidia.yaml`. Output is deterministic
  so the file ends up correct today, but a future change to either unit
  silently loses the race depending on systemd parallelization. The
  duplicate dnf install is a no-op.
  Closing condition: drop the `nvidia-container-toolkit` line from
  `build.sh`'s `dnf5 install`, drop the `nvidia-cdi-generate.service`
  heredoc and its `systemctl enable`, drop the vendored
  `nvidia-container-toolkit.repo` `cp` and the file itself if no
  consumer remains (or keep them for vendor-drift-watch coverage).
  PR #13's stated benefit ("distrobox-GPU on `:latest`") was already
  provided by upstream akmods before the PR; this item un-does the
  net-no-op work.

- [x] **26. Extend `build-private-ml.yml` path filter to include vendored `.repo` files.** _(2026-05-29 — obsoleted by removal)_
  Obsoleted by item #33: the private-ml variant, its `build-private-ml.yml`
  workflow, and `build_files/mullvad.repo` were retired, so there is no
  separate variant-CI path filter to maintain. `vendor-drift-watch.yml` no
  longer watches `mullvad.repo`.

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
  - No `schedule` — Renovate opens PRs as soon as an upstream fix lands,
    rather than batching to a weekly window, so security-relevant base/CVE
    bumps surface promptly. Merge cadence is still human-controlled.
  - No auto-merge — every PR reviewed (matches [[project-hardening-philosophy]]:
    closed by default + explicit opt-in).
  - Renovate is the **sole** dependency bot. Dependabot
    (`.github/dependabot.yml`) was retired so the two don't open duplicate
    GitHub-Action PRs; Renovate covers Actions *and* container digests *and*
    the scanner env vars, and it SHA-pins.

  Activation (one-time UI step) is **done** — Renovate installed on
  `rhuze-emryk/emryk-ml` and confirmed running via developer.mend.io
  (2026-05-29). Note: because `renovate.json` is committed, Renovate skips the
  "Configure Renovate" onboarding PR and runs directly.

- [x] **15. SELinux audit + explicit declaration.** _(2026-05-22)_
  Verified the running Kinoite image: SELinux is **enforcing**, targeted
  policy. Asserted explicitly in this image via shipped
  `/etc/selinux/config` rather than inheriting the Fedora default
  (matches the #9 pattern). The ML-relevant boolean
  `container_use_dri_devices` is ON by default — required for containers
  (distrobox, podman) to access the GPU's DRI devices for CUDA / ML
  workloads. We do not change it; documenting only.

  Other container booleans are off by default and we leave them that
  way: `container_manage_cgroup`, `container_use_devices`,
  `container_modify_selinux_labels`, etc. — each represents a
  capability that should be opt-in per workload, not blanket-enabled.

- [x] **16. Flatpak auto-update timer.** _(2026-05-22)_
  `flatpak-system-update.timer` enabled explicitly in `build.sh`. Fedora's
  flatpak package ships this timer with a preset that enables it by
  default, so this commit just asserts the secure default at the image
  layer (matches #9 pattern). Cadence is the upstream default (daily).
  Covers Firefox, Mullvad GUI, and any other system-installed flatpak
  (user-scoped flatpaks update via the desktop UI or each user's own
  `flatpak update`).

- [x] **17. Pin wheel sudo to require a password.** _(2026-05-22)_
  Ship `/etc/sudoers.d/99-emryk-wheel` (mode 0440) with
  `%wheel ALL=(ALL) ALL` — no NOPASSWD. The 99- prefix means this
  drop-in is the last loaded under `/etc/sudoers.d/`, so it overrides
  anything an upstream package might ship at a lower prefix. Matches
  the Fedora default but asserts it at the image layer so a future
  upstream change cannot silently relax it. Customers who want
  passwordless sudo can ship their own `99zz-` drop-in but must do so
  deliberately.

- [ ] **21. shellcheck the build-time payload guard.**
  `build_files/verify-payload-rpm-owned.sh` (PR #4) is not covered by
  the `shellcheck` step in `build.yml`, which only lints `build.sh`. Add
  `shellcheck build_files/verify-payload-rpm-owned.sh` to that lint step.

- [x] **22. Sign by digest instead of per-tag.** _(2026-06-11)_
  `build.yml` iterated `for tag in …; cosign sign --key …
  $IMAGE_FULL:$tag`. All tags resolve to the same digest, so this
  created N signature manifests for identical content. Resolved in
  PR #47: a single `cosign sign --key … $IMAGE_FULL@$DIGEST` using the
  digest already captured by `--digestfile`; the dead `TAGS` env var
  became the used `DIGEST`. Also removes tag re-resolution at sign
  time, so a concurrent push can no longer change what gets signed.

- [x] **23. Drop dead inputs from the `build.yml` concurrency key.** _(2026-06-11)_
  `build.yml` referenced `${{ inputs.brand_name }}` and
  `${{ inputs.stream_name }}` in its concurrency group, but no
  `inputs:` of those names were declared on the workflow — both
  evaluated empty. Resolved in PR #47 by deleting the references;
  effective grouping behavior unchanged.

- [ ] **27. Polish `vendor-drift-watch.yml`.**
  Three small papercuts surfaced in the post-PR-#18 review of the new
  drift-watch workflow:
  - **Diff exit-code handling**: `if diff … ; then drifted=false ; else drifted=true ; fi`
    treats exit code 2 (file missing/unreadable) the same as exit
    code 1 (drift detected), producing an empty-body issue instead
    of failing the run loudly. Distinguish them with a `case $?`.
  - **Idempotent issue lookup**: `gh issue list --search 'in:title "${title}"'`
    relies on GitHub's tokenized issue search and `--jq '.[0].number'`
    blindly takes the top hit. Once multiple drift issues coexist
    (titles share `.repo drifted from upstream`), the dedup query
    may return the wrong issue. Add a `vendor-drift` label on
    creation and filter by that label with an exact `select(.title == $title)`
    jq predicate.
  - **Cron-time comment reversed**: comment claims `13:00 UTC = 09:00 ET (winter) / 08:00 ET (summer)`,
    but 13:00 UTC is 08:00 EST (winter) and 09:00 EDT (summer) —
    one-line comment fix.

- [ ] **28. Use `install -m 0644` for vendored `.repo` copies.**
  `build.sh` `cp /ctx/tailscale.repo …` and
  `cp /ctx/nvidia-container-toolkit.repo …` use bare `cp`,
  while every other config drop in the script uses
  `install -m 0644` (cosign.pub, policy.json, registries.d, firewalld
  zones, selinux config, sudoers, bootc service drop-in). Fine today
  under Fedora's default 0022 umask; latent fragility if a future
  builder hardening sets a tighter umask. One-line cleanup for
  consistency.

- [ ] **29. Tighten path filters so docs-only PRs don't trigger full image builds.**
  `build.yml`'s push `paths-ignore` only excludes `**/README.md`, and
  its `pull_request` trigger has no path filter at all — so any PR
  touching `SECURITY-TODO.md`, `ONBOARDING.md`, `SECURITY.md`,
  `KEY-POLICY.md`, or `docs/**` kicks off a full multi-GB bootc image
  build + grype + syft + cosign + attestations (~30–60 min on
  ubuntu-24.04, observed first-hand on PR #17 which was
  SECURITY-TODO-only). Add a `paths-ignore` block to the
  `pull_request` trigger and extend the push one. No security
  improvement; pure CI-budget conservation.

- [x] **30. CI guard: NVIDIA akmods kernel must match the base kernel.** _(2026-05-29)_
  `akmods-nvidia-open` ships kernel modules prebuilt for one kernel, encoded
  in its tag (`…:main-44-<kver>…`). `kinoite-main` advances its kernel
  independently, and Renovate's `pinDigests` can only bump the akmods
  *digest*, never the `<kver>` string in the tag — so a base bump can pair a
  new kernel with stale modules. The build still succeeds; the host boots to a
  black screen. `build.yml` now parses `<kver>` from the Containerfile, reads
  the built image's actual `kernel-core` (`buildah run … rpm -q`), and fails
  the build with a "bump the akmods tag to `main-44-<kver>`" message on
  mismatch — caught on the Renovate PR, not at a customer's boot. Only the
  base needs this; `Containerfile.private-ml` inherits the already-validated
  emryk-ml image by digest.

- [x] **31. Update cadence + auto-merge of green base digest bumps.** _(2026-05-29)_
  Two coupled changes that define how upstream fixes reach the image:
  - **Scheduled rebuild dropped from nightly to weekly** (`build.yml`
    `cron: '05 10 * * MON'`). Measured: 23/23 nightlies produced distinct
    digests, but that is build non-determinism, not content change — the base
    is digest-pinned, so a scheduled rebuild only refreshes the ~20
    dnf-layered packages. Kernel/userland/driver updates do **not** ride this
    cron; they arrive only when the digest pin moves (Renovate). Weekly cuts
    ~85% of the sign/attest/push churn; `workflow_dispatch` covers urgent
    out-of-band layered fixes; and every base-bump merge triggers a build
    anyway, so layered packages refresh on each bump *plus* weekly.
  - **Renovate auto-merges container `digest` updates once CI is green**
    (`renovate.json` packageRule). This makes a new kinoite-main/akmods image
    available within ~1h of upstream publishing, hands-off. It is safe because
    (a) the control gate is the customer **reboot** (fetch-only timer, #7), not
    the merge — auto-merge only makes a tested image *available*; and (b) the
    kernel<->akmods coupling check (#30) is the interlock — a kernel-moving
    kinoite-main bump fails that check and is blocked from auto-merging until
    the akmods tag is bumped by hand. Tag/version changes are not `digest`
    updates and are never auto-merged.
  - Also enabled `osvVulnerabilityAlerts` + a `security`-labelled
    `vulnerabilityAlerts` config so CVE-fix PRs (for deps that carry advisory
    metadata — Actions, future pip/etc.) are surfaced and prioritised; these
    stay human-merged.

  Requires repo settings: "Allow auto-merge" (General) and Dependabot
  **alerts** (Code security) enabled — done via `gh api` at this commit.
  Branch protection on `main` requires the "Build and push image" check
  (`strict=false`; admins may override; no required reviews so Renovate
  auto-merge still works) — enabled via `gh api` 2026-05-29, so the
  "merge only when green" guarantee holds by construction for every path
  (Renovate, `gh --auto`, manual). Without it, `gh --auto` merges
  immediately and only Renovate's own CI-gating protects the branch.

- [x] **32. Nudge the operator when a security update is staged.** _(2026-05-29)_
  `bootc-fetch-apply-updates.timer` stages updates silently and never reboots
  (#7) — correct for training jobs, but it means a fix can sit downloaded-but-
  inactive indefinitely with no signal. Shipped via `build.sh`:
  - `/usr/libexec/emryk/update-nudge.sh` reads `bootc status --json` (parsed
    with `python3` — no `jq` dependency) and, when a staged deployment exists,
    writes a login banner to `/run/motd.d/95-emryk-update.motd` so every
    SSH/console login (pam_motd) sees "a system update is staged — reboot to
    apply: `sudo systemctl reboot`". Best-effort kernel-change note: reads the
    *staged* deployment's own `usr/lib/modules` so a rollback's kernel can't be
    mistaken for it; degrades to the generic message if unreadable.
  - `/run` is tmpfs, so the banner **self-clears** on the reboot that applies
    the update; `emryk-update-nudge.timer` (OnBootSec=2min, every 30min)
    re-evaluates so it appears/disappears with the staged state.
  - Chosen channel: MOTD only. Robust for an SSH/remote-desktop cloud
    workstation and free of session/D-Bus fragility. A KDE/Cockpit secondary
    channel can be layered later if customer signal asks for it.
  No auto-reboot anywhere — the operator still chooses when to apply.

- [x] **33. Retire the `:latest-private-ml` (Mullvad) variant; document private egress instead.** _(2026-05-29)_
  Baking a single commercial VPN vendor (Mullvad) into a shipped image cut
  against the project's no-lock-in principle: if the vendor degrades (an
  acquisition, a policy change) or its repo/keyring moves, every image carries
  that liability and removal becomes a forced migration. Resolved by removal,
  not hardening:
  - Deleted `Containerfile.private-ml`, `build_files/private-ml-install.sh`,
    `build_files/mullvad.repo`, and `.github/workflows/build-private-ml.yml`;
    dropped the `mullvad` entry from `vendor-drift-watch.yml`.
  - The base (`:latest`) stays Tailscale-only — Tailscale is justified
    infrastructure (the management/access plane, with Headscale as an escape
    hatch), not a discretionary add-on.
  - Private egress is now an opt-in recipe (`docs/recipes/private-egress.md`):
    route through a Mullvad exit node via the Tailscale already in the image
    (no vendor embedded), or layer the standalone Mullvad client yourself.
  - `:latest-private-ml*` tags are **deprecated** — left in the registry for
    anyone pinned to them, but no new builds or security updates. README and
    SECURITY.md document the move to `:latest`.

- [ ] **34. `cosign verify --key` fails under cosign v3.**
  Observed 2026-06-05: `cosign verify --key cosign.pub …:latest` fails
  under cosign v3.0.6 with `no matching attestations: expected key
  signature, not certificate` — by tag, by digest, and with
  `--insecure-ignore-tlog`. The same command under v2.6.1 (the version
  the pipeline signs with) returns VERIFIED, so the signature itself is
  good; this is a v3 verify-side behavior change. Leading hypothesis:
  v3 enumerates the keyless (Fulcio-cert) provenance/SBOM OCI referrers
  and trips on them when `--key` is given. A customer installing
  current cosign and following the README hits a verification failure —
  worse optics than no signing. README now documents the v2 requirement
  as an interim measure. To do: confirm the referrer hypothesis against
  a current published digest, then find the v3 invocation that scopes
  verification to the `.sig` (or adjust signing) so the documented
  command works on whatever `brew install cosign` / distro packages
  ship today.

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
- 2026-05-29 — item 14 follow-through: Renovate confirmed installed/running (developer.mend.io); Dependabot retired and Monday schedule dropped so it is the sole bot and opens PRs promptly (PR #20); Renovate PRs auto-assigned to the maintainer (PR #22).
- 2026-05-29 — item 30 done: `build.yml` now fails when the `akmods-nvidia-open` tag kernel diverges from the base `kinoite-main` kernel, closing the silent-drift gap that Renovate digest-pinning cannot cover.
- 2026-05-29 — item 31 done: scheduled rebuild dropped nightly→weekly (Mondays); Renovate auto-merges green container `digest` bumps (interlocked by the #30 kernel<->akmods check); OSV/security vulnerability alerts enabled; repo "Allow auto-merge" + Dependabot alerts enabled via `gh api`.
- 2026-05-29 — item 32 done: staged-update login nudge shipped (`emryk-update-nudge` timer + `/run/motd.d` banner via `build.sh`); MOTD-only, self-clearing on reboot, best-effort kernel-change note, no auto-reboot.
- 2026-05-29 — branch protection enabled on `main` (required check "Build and push image", strict=false, admin-overridable, no required reviews) via `gh api`, completing the #31 auto-merge safety model — merges now gate on green CI by construction, not just by Renovate's good behaviour.
- 2026-05-29 — item 33 done: private-ml (Mullvad) variant retired (4 files deleted + `vendor-drift-watch.yml` mullvad entry dropped); single image (`:latest`) going forward; private egress moved to an opt-in recipe (`docs/recipes/private-egress.md`) using Tailscale's Mullvad exit nodes; `:latest-private-ml*` tags deprecated, not deleted.
- 2026-05-22 — item 8 done: SLSA build provenance + CycloneDX SBOM attestations added to both publish workflows; pushed to GHCR as OCI referrers. Three independent trust signals per image now.
- 2026-05-22 — item 14 done: `renovate.json` shipped (action SHA + base-image digest pinning, custom managers for GRYPE_VERSION/SYFT_VERSION, weekly schedule, no auto-merge). Maintainer must install the Renovate GitHub App at github.com/apps/renovate for the config to activate.
- 2026-05-22 — item 15 done: SELinux audited (enforcing/targeted, container_use_dri_devices on) and explicitly declared via shipped `/etc/selinux/config`.
- 2026-05-22 — item 16 done: `flatpak-system-update.timer` explicitly enabled (Fedora preset already enables it; asserting in build.sh).
- 2026-05-22 — item 17 done: wheel-requires-password asserted via `/etc/sudoers.d/99-emryk-wheel` (last-loaded drop-in overrides any future upstream NOPASSWD).
- 2026-05-22 — **SECURITY-TODO is empty.** Backlog closed; ongoing hygiene runs via Renovate (#14), the auto-update timer (#7), and the scheduled key rotation (#12).
- 2026-05-23 — items 3 (grype) and the SBOM half of 8 (syft + attest-sbom) re-homed from `build.yml`/`build-private-ml.yml` to a new `.github/workflows/nightly-scan.yml` running daily at 14:00 UTC. Per-push builds were getting killed by GHA's lost-comms watchdog during multi-GB bootc rootfs cataloging; nightly runs against the published GHCR image with `-vv` keepalive output. Per-push build provenance (cheap) still attested at push time; SBOM attestation now trails by up to 24h. SECURITY.md updated.
- 2026-05-23 — pivoted again: nightly approach also failed (grype on the multi-GB OCI archive was being killed at ~10 min). Switched to RPM-database-only SBOM — extract `/usr/lib/sysimage/rpm` from the built image via `buildah unshare`, run `syft scan dir:./sbom-input` to emit CycloneDX from just the RPM cataloger (seconds), then `grype sbom:./sbom.cdx.json` to scan the SBOM (also seconds). Both moved back to per-push in `build.yml` + `build-private-ml.yml`; `nightly-scan.yml` deleted. Coverage tradeoff: RPM-installed packages only — audited build.sh/private-ml-install.sh to confirm every third-party payload is a dnf install (no curl|tar of vendor binaries). SBOM attestation back at push time. SECURITY.md updated.
- 2026-05-23 — addressed Node.js 20 deprecation warning on the build workflows. `redhat-actions/buildah-build` SHA-bumped to `061ffd31…` (post-v2.13 main commit that ships `node24` — upstream hadn't released a tagged version yet at audit time). `redhat-actions/push-to-registry` inline-replaced with `buildah push --digestfile=…` + `docker://…` — upstream had no Node 24 PR and the repo looked effectively unmaintained, so the supply-chain dependency was dropped entirely. `docker/login-action` (`@v4.1.0`) was already on `node24`; `actions/attest-sbom` (also Node 20 deprecation) was migrated to `actions/attest@v4.1.0` in the same day's commits. Per-push builds re-verified post-change: both images push, sign, attest, and the SBOM attestation still returns 2200+ components.
- 2026-05-26 — `build-disk.yml` audit. Confirmed Node 20→24 clean (checkout@v6, upload-artifact@v7.0.1). Aligned `ublue-os/remove-unwanted-software` pin across all three workflows (`954a816`). Added SLSA build-provenance to the disk-image artifacts via `actions/attest-build-provenance@v4.1.0` over the bib output dir (`81c70f1`) — Sigstore-OIDC signed, no new long-lived secret; verified 2 subjects attested per matrix leg. Cosign signing for disk images deliberately deferred (would broaden `COSIGN_PRIVATE_KEY` to a third workflow; no scheduled distribution stream yet to justify).
- 2026-05-26 — discovered `build-disk.yml` had been silently broken since template-time (no one had ever dispatched it). ISO leg referenced `./disk_config/iso.toml` which didn't exist (template was later split into iso-kde / iso-gnome); fixed to point at `iso-kde.toml` and removed unused `iso-gnome.toml`. qcow2 leg failed with `missing required info: DefaultRootFs` because Fedora bootc base images don't declare a default rootfs type; fixed by passing `--rootfs btrfs` to bib (matches Kinoite/Ublue convention, enables snapshot/rollback). Also fixed `iso-kde.toml`'s kickstart `bootc switch` URL — still pointed at the upstream `ublue-os/image-template`, would have pivoted any installed system to the wrong image (`8df4742`).
- 2026-05-27 — item 3/item 8 strengthened: shipped `build_files/verify-payload-rpm-owned.sh`, invoked from both `Containerfile` and `Containerfile.private-ml` immediately before `bootc container lint` (PR #4, `eb91326`). Walks `/usr/{bin,sbin,libexec,lib,lib64,local}` and `/opt`, batches the file list through `xargs -L 500 rpm -qf`, fails the build on any non-allowlisted unowned file. The RPM-only SBOM scope (previously a manual discipline depending on every payload being `dnf5 install`d in `build.sh`/`private-ml-install.sh`) is now mechanically enforced. Allowlist covers bootc/rpm-ostree machinery, fc-cache output, systemd post-install symlinks, atomic-desktop dracut/bootupd/tmpfiles, glibc nss_db, Broadcom firmware NVRAM mappings, and two known false-positives (`/usr/bin/nvidia-container-toolkit`, `/usr/libexec/fedora-kinoite-plasmalogin-workaround` — both verifiably dnf-installed upstream but `rpm -qf` misreports in this image type; possible same class as the bug that made `rpm -qal` report 5000+ phantom-unowned files when the guard initially tried that approach).
- 2026-05-27 — `build-private-ml.yml` got a `pull_request` trigger (PR #5, `e913494`). Path filter mirrors the existing push trigger plus `build_files/verify-payload-rpm-owned.sh`, so guard-script or variant-script changes get variant CI before merge instead of only post-merge via `workflow_run`. Closes the gap where PR #4 itself only exercised the new guard against the base image, relying on luck that the allowlist also covered private-ml-install.sh output (it did).
- 2026-05-28 — **Backlog reopened** with items 18–23 from a full-codebase security review. Top concern is #18 (Unsloth Studio quadlet: unpinned `:latest` docker.io pull, root-privileged container with full GPU, no-auth loopback bind that trusts every local user). #19 vendors the last two curl-piped vendor `.repo` files. #20 follows through on #3's "flip to `--fail-on critical` once triage exists." #21–23 are CI/registry hygiene.
- 2026-05-28 — items 18 + 19 closed via the private-ml pivot (PRs #11–#16) and the drift-watch workflow (PR #18). Item 18 obsoleted by removal (Quadlet deleted in PR #11; rootless recipe at `docs/recipes/unsloth-studio.md` in PR #12). Item 19 closed by vendoring `build_files/mullvad.repo` + `build_files/nvidia-container-toolkit.repo` (PR #14) and converting the install scripts to `cp` (PRs #14 + #16). Drift-watch follow-up landed in PR #18 (#17 added the SECURITY-TODO entries on main).
- 2026-05-28 — post-pivot code review surfaced six new items (#24–#29). #24 closes the `gpgcheck=0` gap on the vendored nvidia repo and amends #19's overbroad signature-verification claim. #25 unwinds PR #13's redundant duplication of upstream akmods-provided `nvidia-container-toolkit` + CDI generator service. #26 fixes a path-filter gap that makes drift-refresh PRs skip variant CI. #27–#29 polish the new drift-watch workflow, normalise file-copy permissions, and tighten CI path filters so docs-only PRs don't trigger full image builds. Trivial stale-doc fixes (recipe prerequisites table, README variant-tag descriptions, drift-watch cron comment) landed inline with this update.
- 2026-06-11 — items 22 + 23 closed (PR #47): publish loop now signs the manifest digest once instead of per-tag (no tag re-resolution at sign time), and the dead `inputs.brand_name`/`inputs.stream_name` references were dropped from the `build.yml` concurrency group.
- 2026-06-11 — repo-review remainders landed: README/`private-egress.md` now state the Tailscale dependency explicitly (one deliberate vendor commitment; Headscale documented as the self-hosted escape hatch; Mullvad-exit-node recipe flagged as Tailscale-SaaS-only). `anaconda-iso` leg removed from `build-disk.yml` and `iso-kde.toml` deleted — the ISO/local installer was dropped from the roadmap; qcow2 (cloud image) is the deliverable. Item 34 opened for the cosign v3 `verify --key` failure; README documents the v2 requirement until it's root-caused.
