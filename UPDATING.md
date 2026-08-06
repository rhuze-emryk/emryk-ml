# Maintainer release and recovery runbook

This is the current operational runbook. [KEY-POLICY.md](KEY-POLICY.md) governs
signer changes; [SECURITY.md](SECURITY.md) defines the assurances being tested.

## Release cadence and prerequisites

The `Build container image` workflow runs weekly on Monday and may be dispatched
manually from the default branch. Pushes and pull requests validate but do not
publish. The two image names remain:

- `ghcr.io/rhuze-emryk/emryk-ml` (NVIDIA)
- `ghcr.io/rhuze-emryk/emryk-ml-intel` (Intel)

The protected `production-signing` environment must be restricted to the
default branch and require a maintainer reviewer. It contains exactly these
online signing secrets:

- `SIGNING_SECRET`: encrypted active cosign private-key bytes
- `SIGNING_PASSWORD`: password for that encrypted key

The workflow exposes them only as `COSIGN_PRIVATE_KEY` and `COSIGN_PASSWORD` in
the signing step. The offline recovery private key and its passphrase never
belong in GitHub.

## Normal weekly release

1. Review Renovate, vendored dependency drift, and open pull requests in the
   Monday repository cockpit. Resolve red base/kernel coupling PRs before
   releasing.
2. Open the scheduled workflow run. Both `Build and scan image` legs must build
   the named Containerfile target, run payload and bootc lint, produce the
   RPM-database SBOM, and pass the critical-CVE gate.
3. Confirm the log shows one immutable staged digest for each variant.
4. Wait for both `Boot staged image` legs. They build ephemeral AMD64 QCOW2s
   from those exact digests and boot with KVM/OVMF. Missing KVM or firmware is a
   failure, not an emulation fallback. On failure, inspect the uploaded serial
   and journal diagnostics; disks and CI credentials are never artifacts.
5. Only after all four build/smoke legs pass, review the pending
   `production-signing` deployment. Approve only the digests shown in the run.
6. The publish job signs each digest, verifies it against `cosign.pub`, promotes
   that digest to `latest`, `YYYYMMDD`, and `latest.YYYYMMDD`, then attaches
   build provenance and the already-scanned SBOM.
7. Perform the live checks below against both variants before closing the
   release task.

Rejecting or leaving the environment approval pending is safe: release tags do
not move. The unsigned staging tag is not accepted by hosts enforcing the
signature policy.

## Live verification

Resolve and record both release digests:

```bash
skopeo inspect --format '{{.Digest}}' \
  docker://ghcr.io/rhuze-emryk/emryk-ml:latest
skopeo inspect --format '{{.Digest}}' \
  docker://ghcr.io/rhuze-emryk/emryk-ml-intel:latest
```

Verify their active-key signatures:

```bash
cosign verify --key cosign.pub --new-bundle-format=false \
  ghcr.io/rhuze-emryk/emryk-ml@sha256:REPLACE_WITH_NVIDIA_DIGEST
cosign verify --key cosign.pub --new-bundle-format=false \
  ghcr.io/rhuze-emryk/emryk-ml-intel@sha256:REPLACE_WITH_INTEL_DIGEST
```

Verify provenance and download the SBOM for both digest-qualified names:

```bash
gh attestation verify \
  oci://ghcr.io/rhuze-emryk/emryk-ml@sha256:REPLACE_WITH_NVIDIA_DIGEST \
  --repo rhuze-emryk/emryk-ml
gh attestation download \
  oci://ghcr.io/rhuze-emryk/emryk-ml@sha256:REPLACE_WITH_NVIDIA_DIGEST \
  --repo rhuze-emryk/emryk-ml \
  --predicate-type https://cyclonedx.org/bom

gh attestation verify \
  oci://ghcr.io/rhuze-emryk/emryk-ml-intel@sha256:REPLACE_WITH_INTEL_DIGEST \
  --repo rhuze-emryk/emryk-ml
gh attestation download \
  oci://ghcr.io/rhuze-emryk/emryk-ml-intel@sha256:REPLACE_WITH_INTEL_DIGEST \
  --repo rhuze-emryk/emryk-ml \
  --predicate-type https://cyclonedx.org/bom
```

Confirm the SBOM contains Fedora distro metadata and a non-vacuous RPM component
set. It is an RPM-database inventory with explicit non-RPM payload exceptions,
not a filesystem inventory.

## Base/kernel coupling

The NVIDIA akmods image tag embeds the kernel version for which its modules were
built. Renovate can update a base digest without editing that readable tag.
`Verify NVIDIA akmods kernel matches base kernel` deliberately fails if the
Kinoite kernel and akmods tag differ.

When that happens:

1. Read the built image's reported kernel version in the failed job.
2. Change the `akmods-nvidia-open:main-44-<kernel>` tag in `Containerfile` to
   that exact version.
3. Let Renovate update the new tag's digest, or independently resolve and review
   the digest before committing it.
4. Require the normal build, scan, and hosted boot checks. Do not infer physical
   GPU success from module metadata alone.

## Out-of-band security release

Merge the minimal reviewed fix, dispatch `build.yml` on the default branch, and
follow the normal gated flow. The same two-variant gate applies; urgency does
not justify promoting an unbooted digest. Use the hardware canary when the fix
touches the NVIDIA kernel, driver, toolkit, CDI, SELinux device policy, or GPU
container path.

## Planned active-key rotation

Follow [KEY-POLICY.md](KEY-POLICY.md). The key point is fleet evidence: a host
that has merely staged the transition image does not yet trust the next key.
Record `bootc status --json` evidence that each managed host has booted the
transition deployment before replacing environment secrets. Do not use an
elapsed waiting period as a substitute.

## Active-key compromise

Do not approve the ordinary active-key publish job. Build an isolated incident
candidate that removes the compromised key and installs a freshly generated
active public key alongside the permanent recovery public key. Let both hosted
VM legs pass, then use the offline procedure and
`scripts/offline-recovery-release.sh` from a controlled machine. The script
refuses a private key stored inside this repository, signs and verifies the
digest before tag promotion, and does not use GitHub signing secrets.

Hosts that booted the recovery-key bootstrap can accept this release. Older
hosts are manual-recovery cases and must be handled through console access or a
known-good deployment. Preserve incident evidence and revoke/replace the
protected active secrets only after containment.

## AMD64 QCOW2

`build-disk.yml` accepts `variant` (`nvidia` or `intel`) and an optional source
tag. It resolves the chosen tag to a digest before invoking the digest-pinned
bootc-image-builder. AMD64 QCOW2 is the only supported disk deliverable. The
workflow may upload the result to Actions or the configured S3 destination;
neither path is part of container publication.
