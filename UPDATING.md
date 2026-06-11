# Updating Emryk ML (maintainer runbook)

Step-by-step procedures for keeping the image current. For *why* it works this
way — the ancestry, the two planes, the automation model — read
[`docs/update-strategy.md`](docs/update-strategy.md) first. For the
customer-facing runtime behaviour, see the **Updates** section of
[`README.md`](README.md).

---

## What happens without you

These open and merge on their own; you only review/merge (and most don't even
need that). One caveat applies to all of them: **nothing publishes without
you.** Every run that pushes to the registry — push to `main`, the weekly
cron, `workflow_dispatch` — pauses at the `production-signing` environment
until a maintainer approves it in the Actions UI (PR #41, KEY-POLICY.md
"GitHub Environment runbook"). Automation gets changes *merged* unattended;
the registry only moves after your approval click.

- **Base image digest bumps** (`kinoite-main`, `akmods-nvidia-open`, the variant
  base) — Renovate opens a PR, assigns it to you, and **auto-merges it once CI
  is green**. New kernel/userland/driver lands here.
- **GitHub Action SHAs** and `GRYPE_VERSION` / `SYFT_VERSION` — Renovate PR,
  assigned to you, human-merged.
- **Known-CVE dependency fixes** — Renovate, labelled `security`, human-merged.
- **Vendored `.repo` drift** — `vendor-drift-watch.yml` opens/updates an issue
  weekly if Tailscale/Mullvad/NVIDIA-toolkit upstream changed.
- **Weekly rebuild** — `build.yml` `cron: '05 10 * * MON'` refreshes the
  ~20 layered `dnf` packages.

Renovate runs on a **weekly schedule** — before 09:00 UTC Mondays, just ahead
of the 10:05 rebuild cron — and *version* updates additionally wait out a
3-day cool-down so yanked or broken upstream releases never reach a PR
(PR #37). Security/vulnerability PRs bypass both and open at any time. To
force a run mid-week (e.g. to pick up a fresh `kinoite-main` digest), tick the
checkbox on the **Dependency Dashboard** issue. Renovate is the only
dependency bot (Dependabot was retired).

---

## What needs you

### 1. Rolling the base kernel forward (the coupling dance)

This is the **one** routine task automation can't finish, because the NVIDIA
`akmods` tag encodes a kernel version that Renovate's digest-pinning can't
change. You'll know it's needed when **a Renovate `kinoite-main` digest PR fails
the "Verify NVIDIA akmods kernel matches base kernel" check** with a message
like:

> kinoite-main now ships kernel `7.1.2-200.fc44.x86_64` but the
> akmods-nvidia-open tag in Containerfile is pinned to `7.0.4-200.fc44.x86_64`…

Procedure:

1. Take the new kernel string from the error message (e.g. `7.1.2-200.fc44.x86_64`).
2. In `Containerfile`, edit the `akmods-nvidia-open` `FROM` line's **tag**:
   ```
   FROM ghcr.io/ublue-os/akmods-nvidia-open:main-44-7.1.2-200.fc44.x86_64@sha256:… AS nvidia
   ```
   Change `main-44-<old-kver>` → `main-44-<new-kver>`. Leave the `@sha256:` as
   is — Renovate will re-pin the digest for the new tag on its next run (or run
   `skopeo inspect --format '{{.Digest}}' docker://ghcr.io/ublue-os/akmods-nvidia-open:main-44-<new-kver>`
   and paste it now).
3. Push to the Renovate PR branch (or open your own). The coupling check should
   now pass.
4. Merge. (If you edited the akmods tag yourself, this is a tag change, not a
   `digest` update, so it won't auto-merge — merge it by hand.)

> If ublue hasn't yet published an `akmods-nvidia-open` image for the new
> kernel, **don't merge the kinoite-main bump** — wait. Merging would ship
> mismatched modules. The coupling check protects you here.

### 2. Urgent out-of-band fix (layered package can't wait for Monday)

A CVE in a layered package (e.g. `cockpit`, `tailscale`,
`nvidia-container-toolkit`) doesn't ride a digest bump — it's only refreshed by
a rebuild. To pull it now instead of waiting for the weekly cron:

- **Actions → "Build container image" → Run workflow** (`workflow_dispatch`) on
  `main`. The rebuild re-pulls all layered packages at their current versions
  and republishes `:latest`. The run pauses at the `production-signing`
  environment — approve it, or nothing publishes.

### 3. Responding to a Fedora kernel/security advisory

You consume `kinoite-main`, not Fedora directly, so the actionable event is
**"kinoite-main's digest moved"**, which Renovate already chases. To act fast:

1. If a Renovate `kinoite-main` PR is already open → review and merge (or let it
   auto-merge once green). Handle the coupling dance (#1) if the check fails.
2. If no PR yet, either Renovate hasn't run (it's scheduled weekly — force a
   run from the Dependency Dashboard issue) or ublue hasn't rebuilt with the
   fix. Don't hand-edit the digest ahead of ublue — you'd lose the matched
   akmods build.
3. Tell customers to reboot if it's urgent (the fix is staged, not active, until
   they do — a login banner reminds them (`emryk-update-nudge`, SECURITY-TODO #32)).

### 4. Refreshing a vendored `.repo` file

When `vendor-drift-watch.yml` files an issue: review the diff in the issue,
confirm the upstream change is legitimate, then run the `curl … -o
build_files/<file>.repo` command from the issue and open a PR. Vendoring is
deliberate (SECURITY-TODO #6/#19) — the point is that a CDN change can't reach
the build until a PR lands here.

---

## After any base bump — verify what published

```bash
# Signed by us
cosign verify --key cosign.pub ghcr.io/rhuze-emryk/emryk-ml:latest

# Built from our source (SLSA provenance)
gh attestation verify oci://ghcr.io/rhuze-emryk/emryk-ml:latest \
  --repo rhuze-emryk/emryk-ml
```

See README **Verifying the image** for the full set (incl. SBOM).

## If a published update misbehaves

Customer-side rollback is `sudo bootc rollback && sudo systemctl reboot`. On the
publishing side, revert the offending PR and let the rebuild republish `:latest`
at the prior-good content; the bad dated tag stays in the registry but `:latest`
moves back.

---

## Required repo settings (already applied)

These make the automation work; listed so they survive a settings audit:

- **Allow auto-merge** (Settings → General) — on.
- **Dependabot alerts** (Settings → Code security) — on (feeds Renovate's
  vulnerability alerts; this is the *alerts* feature, not version updates).
- **Branch protection** on `main` requiring the "Build and push image" check —
  on (`strict=false`, admins may override, no required reviews). This is what
  makes "merge only when green" enforced for *every* path; without it,
  `gh pr merge --auto` merges immediately and only Renovate self-gates on CI.
