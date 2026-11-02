# Tech debt register

Open, non-security engineering debt. Security risks live in
[SECURITY-TODO.md](SECURITY-TODO.md); binding behaviour in
[SECURITY.md](SECURITY.md). Each row names the closing test so an item can be
retired without re-deriving the intent. Remove rows when closed; do not keep a
"done" section here (git history has it).

**Effort** guides who picks an item up: `small` is a self-contained change a
fresh session can finish from this row alone; `decision` needs the maintainer
to choose first; `trust-path` touches signing, promotion or the publish gate and
deserves the most careful review. Verified against the repository on
2026-11-02.

## Build and release pipeline

| Effort | Item | State | Closing test |
|---|---|---|---|
| small | `FEDORA_TOOLS_IMAGE` in `build.yml` still pins `registry.fedoraproject.org/fedora:44`. Only used for skopeo/policy tooling in CI, so nothing is broken, but it should track the image's Fedora major. | Open since the Fedora 45 move (#204). | Pin reads `fedora:45@sha256:…`; Renovate keeps refreshing the digest; publish run green. |
| small | The no-auto-reboot promise (`bootc-fetch-apply-updates` drop-in removes `--apply`) is asserted nowhere. A base change restoring `--apply` would ship unnoticed. | Open. | `tests/boot-smoke-guest.sh` asserts `systemctl show -p ExecStart bootc-fetch-apply-updates.service` contains `bootc upgrade` and not `--apply`. |
| small | Three Actions are pinned to branch commits, not tags, so Renovate never proposes updates: `ublue-os/remove-unwanted-software` (master, 2025-10-10), `redhat-actions/buildah-build` (main, 2026-04-09), `osbuild/bootc-image-builder-action` (main, 2026-05-04). | Open; manual quarterly check is the current practice. | Renovate `customManager` (or `git-refs` datasource) opens PRs for new upstream commits, or a dated comment on each pin records the last manual review. |
| small | Grype downloads its ~100 MB vulnerability database on every build. | Open; low value (~30 s per build). | `actions/cache` keyed on the DB build date; scan step still runs with `GRYPE_DB_AUTO_UPDATE` behaviour documented. |
| decision | `build-disk.yml` is not a required check and boot smoke is skipped on pull requests, so a workflow-only Renovate PR can break publishing unseen (PR #186, ubuntu-26.04 runner, 2026-10-24). | Open. Runner held at ubuntu-24.04 via Renovate + `tests/test-workflow-policy.sh`. | Decide: make `build-disk` required for PRs touching `.github/workflows/`, or run a reduced boot smoke on such PRs. Policy test asserts whichever is chosen. |
| decision | The ubuntu<26 runner hold exists because bootc-image-builder (osbuild) fails on ubuntu-26.04 with a containers-storage mount permission error. | Open; waiting on upstream. | A green `build-disk` dispatch on a newer runner, then lift the Renovate hold and the policy-test pin together. |
| decision | `build-disk.yml` has no `schedule:` and its outputs are not cosign-signed. Disk images (qcow2, ISO) are therefore not a shipped artifact today. | Open since 2026-05-27. | Decide whether disk images ship regularly. If yes: schedule, signing, and a row in SECURITY.md; if no: say so in the README. |
| trust-path | A `security`-labelled Renovate PR merged mid-week publishes nothing until Saturday's cron, and nothing tells the maintainer that. | Open; explicitly wanted (2026-07-06). | A push to `main` carrying a `security`-labelled PR produces exactly one notification saying "merged, not shipped; dispatch to publish now". |

## Image content

| Effort | Item | State | Closing test |
|---|---|---|---|
| decision | `supergfxctl` (laptop dual-GPU switcher) is installed on the NVIDIA image because upstream `nvidia-install.sh` adds it for `IMAGE_NAME=kinoite`. Harmless, unnecessary on a workstation. | Open. | Either remove it after the install step (and check nothing else keys on `IMAGE_NAME`), or document that it is intentional. |
| small | Two payload-guard allowlist entries are known `rpm -qf` false positives (`/usr/bin/nvidia-container-toolkit`, `/usr/libexec/fedora-kinoite-plasmalogin-workaround`): the files are RPM-installed but `rpm -qf` reports them unowned in rpm-ostree-derived images. | Open; root cause unknown, likely an upstream question. | Root cause found and the two entries deleted, or a comment in `verify-payload-rpm-owned.sh` cites the upstream issue. |
| small | `systemd-remount-fs.service` fails on every boot of a composefs host ("overlay: No changes allowed in reconfigure"). Upstream: ostreedev/ostree#3193, fix proposed in #3267. Present on F44 and F45. | Open; cosmetic, but it is the first thing `systemctl --failed` shows a customer. | Upstream fix lands in the base, or the README's known-issues section explains it. |

## Fedora 45 verification on hardware

Config and versions were checked on the first F45 boot (2026-11-01); behaviour
in use was not.

| Effort | Item | State | Closing test |
|---|---|---|---|
| small | Plasma 6.8 on-screen keyboard suppression via `/etc/xdg/kwinrc` `InputMethod=` (PR #63) was written against Plasma 6.6. | Config present on F45; not exercised. | Fresh login on F45 hardware: no OSK at the greeter or in session. |
| small | Podman 6 (cgroups v1 and slirp4netns removed) with existing quadlets and rootless pods. | Not exercised. | A rootless quadlet pod with a custom network and `UserNS=keep-id` starts cleanly on Podman 6.1. |
| small | `ptrace_scope=1` (#207) inside distrobox and dev containers: attaching to a running process now needs root. | Shipped; impact on common ML debugging tools not surveyed. | README recipe listing which tools need `sudo` or `--cap-add SYS_PTRACE`, verified against a distrobox. |

## Upstream reports to file

| Effort | Item | State | Closing test |
|---|---|---|---|
| small | kf6-kwallet ≥ 6.30: `ksecretd --pam-login` dereferences a null collection in `KSecretD::pamOpen` when `kwalletrc` has an empty `Local Wallet=` (upstream commit b8046c37 added the unchecked call). Crashes at every PAM login. Workaround: set `Local Wallet=kdewallet`. | Diagnosed 2026-11-01; not reported. | bugs.kde.org report filed with the backtrace and the two suggested fixes (null check in `pamOpen`; treat an empty `Local Wallet` as unset). |
| small | NVIDIA start-limit drop-ins (PR #202) belong upstream: `ublue-os-nvidia-addons` already carries a drop-in on `nvidia-cdi-refresh.service`. | Not proposed. | Upstream PR opened; once merged and in the base, the local drop-ins are removed. |

## Registry hygiene

| Effort | Item | State | Closing test |
|---|---|---|---|
| decision | GHCR holds 359 tags on `emryk-ml` and 78 on `emryk-ml-intel`, including retired variant tags and daily tags from May 2026. Tag deletion is irreversible, so a retention rule has to be agreed first. | Open. | Written retention rule (which tags are kept, for how long) and a one-off cleanup that leaves `latest`, every `latest.YYYYMMDD` inside the rule, and nothing from retired variants. |
| small | Remote branch `chore/kernel-7.2.11` is superseded by #204 and can be deleted. | Open. | Branch gone; `git branch -r --merged origin/main` shows only `main`. |
