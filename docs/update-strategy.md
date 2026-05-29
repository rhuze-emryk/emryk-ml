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
specific kernel). Everything else — Tailscale, the NVIDIA container toolkit,
the ~20 `dnf` packages, the Firefox flatpak — is layered on by `build_files/`.

Both upstreams are **pinned by digest** in `Containerfile`
(`tag@sha256:…`), so an upstream tag rewrite can never silently change what we
build (SECURITY-TODO #1).

---

## Two planes — keep them separate

Most confusion about "are we getting updates?" comes from conflating these.

### Build-time plane — *what image we publish*

Governed **entirely** by the `FROM … @sha256:` digests in `Containerfile`.
Because we pin by digest, **the published image does not change until a digest
is bumped.** A scheduled rebuild on the *same* pinned digest produces a new
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
  → Renovate detects the new digest (no schedule → within ~hours)
  → Renovate opens a digest-bump PR, auto-assigned to the maintainer
  → CI build runs (incl. the kernel↔akmods coupling check)
  → green → Renovate AUTO-MERGES (SECURITY-TODO #31)        ← hands-off
  → our build publishes :latest
  → customer bootc timer fetches + stages (~8h)
  → customer REBOOTS                                        ← manual, by design
```

The two slow links are deliberate: there is no human gate on the *merge* (the
gate moved to the reboot), and the reboot is the customer's call so training
jobs survive. For a genuinely urgent kernel CVE, the operator reboots promptly
(a login banner reminds the operator when an update is staged — SECURITY-TODO #32).

**Why auto-merging digests is safe here:** the control gate is the *reboot*,
not the merge — auto-merge only makes a *tested* image available; nothing
reboots a workstation. And the coupling check (below) blocks the one dangerous
class of bump.

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
| Vendored `.repo` drift (Tailscale/Mullvad/NVIDIA-ct) | `vendor-drift-watch.yml` (weekly) | Opens an issue; human refresh |
| Layered `dnf` packages | the scheduled / on-merge rebuild | Auto (pulled live each build) |
| Scheduled rebuild | `build.yml` `cron: '05 10 * * MON'` | Weekly |
| Customer fetch/stage | `bootc-fetch-apply-updates.timer` | Auto (~8h), **no reboot** |
| Customer apply (reboot) | operator | **Manual**; a login banner nudges when an update is staged (#32) |

Renovate is the **sole** dependency bot (Dependabot retired, PR #20) and runs
with **no schedule** so security PRs surface promptly; every Renovate PR is
auto-assigned to the maintainer (PR #22).

---

## Why this shape

It reconciles two things that usually pull against each other — *closed-by-
default / reviewed changes* and *fast security response* — by moving the human
control gate from the **merge** to the **reboot**:

- Pinning by digest keeps the supply chain reviewed (every base is a digest in
  git history).
- Auto-merging *green* digest bumps makes new images available within ~1h of
  upstream, with no human in the loop.
- The coupling check is the safety interlock that makes that automation safe.
- The fetch-only timer means the customer still decides *when* a change takes
  effect, so nothing automated ever interrupts a running job.

This is the same closed-by-default + explicit-opt-in through-line that shapes
every other Emryk security choice.
