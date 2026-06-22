# Signing Key Policy

This document describes how the cosign signing key for `ghcr.io/rhuze-emryk/emryk-ml` is managed: where it lives, who can use it, when it gets rotated, and what we do if it leaks.

Audience: maintainers of this repo, plus any commercial customer evaluating Emryk's supply-chain story.

---

## Scope

A single cosign keypair is currently used to sign every image published to `ghcr.io/rhuze-emryk/emryk-ml`. The public half is in this repo at `cosign.pub` and is shipped into every built image at `/etc/pki/containers/rhuze-emryk.pub`. The private half lives only in the GitHub Actions secret `SIGNING_SECRET` on the `rhuze-emryk/emryk-ml` repository.

Installed Emryk Workstation hosts trust this public key absolutely for pulls from the `ghcr.io/rhuze-emryk` namespace — see `build_files/containers-policy.json` and SECURITY-TODO item #2.

---

## Threat model

If `SIGNING_SECRET` is exfiltrated:

- An attacker can sign arbitrary container images as if they were us. Any Emryk Workstation host that pulls a matching tag will accept and stage the malicious image, because the host's `policy.json` requires only that the signature verify against our public key.
- Once such an image boots, the attacker is root on the box.
- The auto-update timer (SECURITY-TODO #7) means this propagates to every running host within ~8 hours of the malicious image being pushed to GHCR.
- **Every signature ever produced before the leak becomes suspect** — we cannot prove the attacker didn't backdate by retaining timestamps.

Compromise of the signing key is the single highest-impact event in this product's threat model.

---

## Access policy

**Where the private key lives:**

- GitHub repository secret `SIGNING_SECRET` in `rhuze-emryk/emryk-ml`. This is the only location the private key should exist outside of an offline backup.
- An offline backup (encrypted, air-gapped) is recommended for disaster recovery. Maintainer's responsibility; not committed anywhere.

**Who can use it:**

- Today: any workflow run on `rhuze-emryk/emryk-ml` triggered by anyone with `write` permission on the repo. This is the GitHub default and is **too permissive**.
- Target: gate `SIGNING_SECRET` behind a GitHub Environment with manual-approval protection. See [GitHub Environment runbook](#github-environment-runbook) below.

**Workflow access boundary:**

- `SIGNING_SECRET` is read only by the "Sign container image" step in `build.yml`. No other step references it. A compromised earlier step in the same job would still expose it, so the GitHub Environment gate is the meaningful boundary.

---

## Rotation cadence

- **Scheduled rotation: annually**, on or near the calendar anniversary of the current key. Calendar-anchored so it does not drift.
- **On-incident rotation: immediately**, the moment compromise is suspected. Do not wait to confirm — rotate first, investigate second.

The next scheduled rotation date is tracked in [SECURITY-TODO.md](./SECURITY-TODO.md) as a dated item in the status log.

---

## Rotation procedure

Rotation is **non-destructive** if you ship a transition image first that trusts BOTH keys. Skip the transition image at your own risk — hosts that update past the rotation point cannot verify images signed with the previous key, and the rollback path breaks.

### Step 1 — generate the new keypair (locally, offline)

```bash
cosign generate-key-pair
# Produces cosign.key (private) and cosign.pub (public) in cwd.
# When prompted, set a strong passphrase. Store the passphrase separately.
```

### Step 2 — ship a transition image that trusts both keys

Before changing what signs images, ship a build that *accepts* both the old and new keys. This is the graceful-rotation window — a host that was on the pre-transition image can still update through the transition image and onward.

1. Add the new public key to the build context: copy the new `cosign.pub` to `cosign-2027.pub` (or whatever calendar year) at repo root. Leave the existing `cosign.pub` in place — for now, both files coexist.
2. Update `build_files/build.sh` to install both keys:
   ```bash
   install -m 0644 /ctx/cosign.pub      /etc/pki/containers/rhuze-emryk.pub
   install -m 0644 /ctx/cosign-2027.pub /etc/pki/containers/rhuze-emryk-2027.pub
   ```
3. Update `build_files/containers-policy.json` to accept either signature:
   ```json
   "ghcr.io/rhuze-emryk": [
     {
       "type": "sigstoreSigned",
       "keyPath": "/etc/pki/containers/rhuze-emryk.pub",
       "signedIdentity": {"type": "matchRepository"}
     },
     {
       "type": "sigstoreSigned",
       "keyPath": "/etc/pki/containers/rhuze-emryk-2027.pub",
       "signedIdentity": {"type": "matchRepository"}
     }
   ]
   ```
   Either entry matching the pulled image is sufficient (logical OR).
4. Commit and push. CI builds and signs the transition image with the OLD key (the GitHub secret has not changed yet).
5. Wait for the auto-update timer to propagate the transition image to all known hosts (~24h conservative). Verify on at least one operator host with `bootc status` that the transition build is booted.

### Step 3 — flip the signing key in GitHub Actions

1. In github.com → Settings → Secrets → Actions, update the value of `SIGNING_SECRET` to the new private key (the contents of `cosign.key` from Step 1).
2. Trigger a new build of `:latest`. CI will sign it with the new key.
3. Hosts on the transition image accept the new signature because their policy.json trusts both keys. Bootc updates land normally.

### Step 4 — retire the old key

After enough time has passed that no in-use host is on a pre-transition image (recommend 30+ days for a fleet of any size):

1. Remove the old key from `containers-policy.json`.
2. Remove the install line from `build.sh`.
3. Delete the old `cosign.pub` from the repo (rename `cosign-2027.pub` → `cosign.pub` if desired, for naming continuity).
4. Commit, push. The new image only trusts the new key. Hosts that somehow got stuck on a pre-transition image will fail to update from this point and will need manual recovery.

### Step 5 — record the rotation

Append to [SECURITY-TODO.md](./SECURITY-TODO.md) status log:

```
- YYYY-MM-DD — signing key rotated. Old key retired YYYY-MM-DD. Next scheduled rotation: YYYY-MM-DD.
```

---

## Incident response

If `SIGNING_SECRET` is suspected of compromise:

1. **Within the hour:** rotate `SIGNING_SECRET` in GitHub Actions to a freshly-generated value. Do not wait for confirmation. The cost of an unnecessary rotation is hours; the cost of waiting on a real compromise is the fleet.
2. **Within the day:** ship a transition image trusting both old and new keys (the standard rotation Step 2). This is necessary even in incident mode — a hard cutover orphans the fleet.
3. **Investigate** what was signed in the window between when the key could have been exfiltrated and when it was rotated. Use the Rekor transparency log: every cosign signature lands in Rekor by default. Cross-reference Rekor entries against your authorized builds.
4. **If unauthorized signatures exist** in Rekor for our key, treat every image signed by the compromised key as suspect. Notify customers. Roll back any hosts that pulled an unauthorized image. Document the incident publicly.
5. **Retire the old key** more aggressively than the scheduled procedure — as soon as you are confident the fleet has the transition image. Do not leave the compromised key as an accepted signer one minute longer than necessary.

---

## GitHub Environment runbook

To move `SIGNING_SECRET` from a repository-level secret to an environment-scoped secret behind a manual-approval gate. This is a one-time setup; do it during the next maintenance window.

1. In github.com → repository **Settings → Environments → New environment**, name it `production-signing`.
2. Under **Deployment protection rules**, enable **Required reviewers** and add yourself (or a maintainers list). Optionally set a **Wait timer** of a few minutes to give yourself a chance to cancel an unintended run.
3. Under **Deployment branches**, restrict to `main` only. Tags and other branches cannot trigger this environment.
4. Under **Environment secrets**, add `SIGNING_SECRET` with the current private key value.
5. In github.com → **Settings → Secrets and variables → Actions**, **delete** the repository-level `SIGNING_SECRET`. From this point only the environment-scoped one exists.
6. Edit `.github/workflows/build.yml` — on the job that does the cosign signing, add:
   ```yaml
   environment: production-signing
   ```
   at the job level (sibling of `runs-on:`).
7. Commit, push. The next *publishing* run — the weekly Monday build or a manual **Run workflow** — will pause at the signing job and require the configured reviewer to approve before the secret is exposed. (A plain push to `main` builds and tests but no longer reaches the signing step, so trigger a `workflow_dispatch` if you want to exercise the gate immediately.)

Note: this **does not** prevent a maintainer who can approve from authorizing a malicious workflow. It prevents accidental exposure (e.g., a PR that accidentally references the secret) and gives a human a chance to inspect each signing event.

---

## Keyless signing roadmap

Sigstore keyless signing — where the workflow's OIDC token from GitHub Actions is exchanged with Fulcio for a short-lived signing certificate, and the signature is logged in Rekor — eliminates the long-lived signing secret entirely. There is no `SIGNING_SECRET` to leak.

This is the modern best practice and the direction this project should move.

- **Target: evaluate keyless by end of 2026.** Stand up a parallel `:latest-keyless` build that signs the same image with both the current keypair and keyless. Validate that customer-side verification works against both.
- **Target: migrate by end of 2027.** Drop the keypair entirely; ship a final transition image that accepts both keypair signatures and keyless; then ship a post-transition image that accepts only keyless. Customer-facing `cosign verify` command updates to use `--certificate-identity` and `--certificate-oidc-issuer`.

Until that migration completes, the rotation policy in this document is operative.
