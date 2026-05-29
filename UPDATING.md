# Updating Emryk ML (maintainer runbook)

Step-by-step procedures for keeping the image current. For *why* it works this
way — the ancestry, the two planes, the automation model — read
[`docs/update-strategy.md`](docs/update-strategy.md) first. For the
customer-facing runtime behaviour, see the **Updates** section of
[`README.md`](README.md).

---

## What happens without you

These run on their own; you only review/merge (and most don't even need that):

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

Renovate runs with **no schedule**, so it reacts within hours of an upstream
change. It is the only dependency bot (Dependabot was retired).

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
  and republishes `:latest`.

### 3. Responding to a Fedora kernel/security advisory

You consume `kinoite-main`, not Fedora directly, so the actionable event is
**"kinoite-main's digest moved"**, which Renovate already chases. To act fast:

1. If a Renovate `kinoite-main` PR is already open → review and merge (or let it
   auto-merge once green). Handle the coupling dance (#1) if the check fails.
2. If no PR yet, ublue may not have rebuilt with the fix. Don't hand-edit the
   digest ahead of ublue — you'd lose the matched akmods build.
3. Tell customers to reboot if it's urgent (the fix is staged, not active, until
   they do — see SECURITY-TODO #32 for the planned in-product nudge).

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
- *Optional belt-and-suspenders:* branch protection on `main` requiring the
  "Build and push image" check, so nothing — including a stray auto-merge — can
  land on a red build.
