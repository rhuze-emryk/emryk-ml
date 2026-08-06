# Update strategy rationale

The operational procedure lives in [UPDATING.md](../UPDATING.md). This note
explains the stable design choices behind it.

- Releases move weekly rather than on every merge, giving operators one
  predictable approval while still allowing a manual security release.
- Container bases and bootc-image-builder are digest-pinned. Renovate proposes
  digest updates; a human-readable NVIDIA akmods tag still carries its kernel
  coupling and CI checks the actual built kernel.
- Both published variants advance together. A failure in either build, scan, or
  hosted boot leg prevents both release tags from moving.
- The candidate is staged once and handed between jobs by immutable digest.
  Signing and verification happen before digest-preserving tag promotion.
- Installed systems fetch and stage signed updates but never reboot themselves.
  The deployment becomes active only at an operator-chosen reboot.
- Rollback retains the previous bootc deployment. It is an availability tool,
  not a substitute for signature verification or incident recovery.
- AMD64 QCOW2 is the only supported disk artifact. Disk inputs are resolved to
  a source digest before bootc-image-builder runs.

The security limits of this model—including trusted-signer compromise, local
configuration drift, RPM-only SBOM scope, and missing physical GPU coverage—are
defined in [SECURITY.md](../SECURITY.md), not here.
