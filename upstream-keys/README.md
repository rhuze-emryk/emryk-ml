# Upstream signing keys

Universal Blue's cosign public keys, used by
[`scripts/verify-upstream-base-signatures.sh`](../scripts/verify-upstream-base-signatures.sh)
to check that every `ghcr.io/ublue-os` base image pinned in the
[`Containerfile`](../Containerfile) was signed by Universal Blue before we build
on it and re-sign the result with our own key.

| File | Role |
|---|---|
| `ublue-os.pub` | Active key; signs current images |
| `ublue-os-backup.pub` | Upstream's rotation key; accepted so a planned rotation doesn't break builds |

Vendored on 2026-10-12. At that time the active key matched three independent upstream
copies (`ublue-os/main/cosign.pub`, `ublue-os/akmods/cosign.pub`, and
`ublue-os/packages/.../ublue-os-signing/src/etc/pki/containers/`).

`vendor-drift-watch.yml` compares these files with upstream every week and opens a
`SECURITY REVIEW` issue on any change. Never update them automatically: confirm a
rotation through an independent Universal Blue channel, then change them in a
reviewed pull request.
