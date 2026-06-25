# Emryk ML: Update Strategy

How upstream changes — security fixes, kernel bumps, driver updates,
package refreshes — actually reach a running Emryk workstation, and what
is automated vs. left to a human.

This is the *explainer*. For the step-by-step maintainer procedures (rolling
the base forward, what to do when the coupling check fails, emergency
out-of-band builds), see [`UPDATING.md`](../UPDATING.md). For the customer-
facing runtime behaviour (the fetch-only timer, rollback), see the
**Updates** section of [`README.md`](../README.md).

---

## The ancestry

```
Fedora 44                       upstream distro; ships CVE fixes continuously
  └─ Fedora Kinoite             official atomic/bootc KDE variant
       └─ ublue-os/kinoite-main Universal Blue's rebuild (+ ublue fixes/codecs).
            │                   Rebuilt DAILY; rolls its kernel forward on
            │                   Fedora's schedule.
            └─ emryk-ml         THIS image: FROM kinoite-main + NVIDIA + hardening

   ublue-os/akmods-nvidia-open  separate ublue image: NVIDIA open kernel modules,
                                PRE-BUILT for one specific kernel (encoded in its
                                tag). Consumed as a build stage, not a base.
```

Two upstreams feed the build: **`kinoite-main`** (the OS, incl. the kernel and
all userland) and **`akmods-nvidia-open`** (the GPU driver, prebuilt to match a
specific kernel). Everything else — Tailscale, the ~20 `dnf` packages, the Firefox flatpak — is
layered on by `build_files/`. (The NVIDIA container toolkit rides in with the
`akmods-nvidia-open` setup, not our `dnf` layer — see SECURITY-TODO #25.)

Both upstreams are **pinned by digest** in `Containerfile`
(`tag@sha256:…`), so an upstream tag rewrite can never silently change what we
build (SECURITY-TODO #1).

---

## Two planes — keep them separate

Most confusion about "are we getting updates?" comes from conflating these.

### Build-time plane — *what image we publish*

Governed **entirely** by the `FROM … @sha256:` digests in `Containerfile`.
Because we pin by digest, **the published image does not change until a digest
is bumped** — and even then, only once the next build publishes it (the weekly
Monday run, or a manual dispatch; a merge alone ships nothing). A scheduled
rebuild on the *same* pinned digest produces a new
manifest (build timestamps/labels differ) but the **same kernel, userland, and
driver** — only the ~20 `dnf`-layered packages can drift, since those are
pulled live at build time.

Consequence: **the weekly cron does not deliver kernel/OS security updates.**
Those arrive only when the `kinoite-main` digest pin moves. (See
SECURITY-TODO #31 for the measurement that established this — 23/23 nightlies
were distinct digests but content-identical at the base.)

### Runtime plane — *what a customer's machine runs*

`bootc-fetch-apply-updates.timer` pulls our published `:latest` every ~8h,
**stages** it, and **never reboots** (SECURITY-TODO #7 — a training job can run
for days). The customer reboots when they choose. So the customer tracks our
published image, which only moves when we publish.

---

## How a Fedora kernel/security fix reaches a customer

```
Fedora ships fix
  → ublue rebuilds kinoite-main (daily) → new digest published
  → Renovate detects the new digest (weekly Monday run; force it
    mid-week from the Dependency Dashboard issue)
  → Renovate opens a digest-bump PR, auto-assigned to the maintainer
  → CI build runs (incl. the kernel↔akmods coupling check)
  → green → Renovate AUTO-MERGES to main (SECURITY-TODO #31) ← hands-off
  → change waits on main until the weekly Monday build —
    or a manual "Run workflow" if the fix is urgent
  → that build pauses at the production-signing
    environment (PR #41)                                    ← maintainer approves
  → our build publishes :latest
  → customer bootc timer fetches + stages (~8h)
  → customer REBOOTS                                        ← manual, by design
```

The slow links are deliberate. There is no human gate on the *merge* — review
moved out of the hot path — but two manual gates remain: the maintainer's
one-click `production-signing` approval before anything reaches the registry,
and the customer's reboot, which is their call so training jobs survive.
Publishing is **weekly** (the Monday build), which batches the maintainer's
approvals into one predictable moment instead of one per merge; an urgent fix
skips the wait via a manual "Run workflow" (UPDATING.md, "When something
genuinely can't wait"). For a genuinely urgent kernel CVE, the operator then
reboots promptly (a login banner reminds the operator when an update is
staged — SECURITY-TODO #32).

**Why auto-merging digests is safe here:** auto-merge only makes a *tested*
image available — it publishes nothing (the `production-signing` approval
gates the registry) and reboots nothing (the customer applies on their own
schedule). And the coupling check (below) blocks the one dangerous class of
bump.

---

## The kernel ↔ akmods coupling (the fragile part)

`akmods-nvidia-open` ships modules **prebuilt for one kernel**, encoded in its
tag:

```
ghcr.io/ublue-os/akmods-nvidia-open:main-44-7.0.4-200.fc44.x86_64@sha256:…
                                            └── kernel version, IN the tag
```

`kinoite-main` advances its kernel independently. Renovate's `pinDigests` can
bump the akmods **digest**, but it can **never** change the `<kver>` *string* in
the tag. So a `kinoite-main` bump can pair a **new** kernel with **old**
modules — the build succeeds, but the host boots to a **black screen** because
the prebuilt modules don't match the running kernel.

**The interlock:** `build.yml` parses `<kver>` from the Containerfile tag, reads
the built image's actual `kernel-core`, and **fails the build on mismatch**
(SECURITY-TODO #30). Because Renovate only auto-merges when CI is green, a
kernel-moving bump is **blocked from auto-merging** until a human bumps the
akmods tag. Routine refreshes sail through; the dangerous case is forced to a
human. This is exactly what makes digest auto-merge safe.

---

## The automation, at a glance

| Concern | Mechanism | Auto or manual |
|---|---|---|
| Base image digests (`kinoite-main`, `akmods`, variant base) | Renovate `pinDigests` | **Auto-merge** when CI green (digest updates only) |
| akmods **tag** kernel string | — | **Manual** (coupling check blocks the merge until done) |
| GitHub Action SHAs, `GRYPE_VERSION`/`SYFT_VERSION` | Renovate | PR, auto-assigned, human-merged |
| Known-CVE deps (Actions, future pip/etc.) | Renovate `osvVulnerabilityAlerts` + `security` label | PR, human-merged |
| Vendored `.repo` drift (Tailscale) | `vendor-drift-watch.yml` (weekly) | Opens an issue; human refresh |
| Layered `dnf` packages | the scheduled rebuild | Auto (pulled live each build) |
| Scheduled rebuild + publish | `build.yml` `cron: '05 10 * * MON'` | Weekly — the only routine publish |
| Publish to GHCR (push/sign/attest) | weekly Monday build + manual `workflow_dispatch`, gated by the `production-signing` environment (PR #41) | **Manual** one-click approval per publishing run; a push/merge alone never publishes |
| Customer fetch/stage | `bootc-fetch-apply-updates.timer` | Auto (~8h), **no reboot** |
| Customer apply (reboot) | operator | **Manual**; a login banner nudges when an update is staged (#32) |

Renovate is the **sole** dependency bot (Dependabot retired, PR #20). It runs
on a weekly Monday schedule with a 3-day cool-down on *version* updates
(PR #37); security PRs bypass the schedule and surface promptly. Every
Renovate PR is auto-assigned to the maintainer (PR #22).

---

## Why this shape

It reconciles two things that usually pull against each other — *closed-by-
default / reviewed changes* and *fast security response* — by moving the human
control gate from the **merge** to two cheap later points: the one-click
**publish approval** and the customer's **reboot**:

- Pinning by digest keeps the supply chain reviewed (every base is a digest in
  git history).
- Auto-merging *green* digest bumps takes code review out of the hot path; the
  remaining human touch before publish is a one-click `production-signing`
  approval, not a review.
- The coupling check is the safety interlock that makes that automation safe.
- The fetch-only timer means the customer still decides *when* a change takes
  effect, so nothing automated ever interrupts a running job.

This is the same closed-by-default + explicit-opt-in through-line that shapes
every other Emryk security choice.
