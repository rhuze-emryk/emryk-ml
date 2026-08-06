# Emryk Workstation onboarding overview

> This is non-authoritative product guidance. Security claims are governed by
> [SECURITY.md](SECURITY.md), release/recovery operations by
> [UPDATING.md](UPDATING.md), and signer lifecycle by
> [KEY-POLICY.md](KEY-POLICY.md).

Emryk ML provides two managed AMD64 Fedora Kinoite bootc images:

- `ghcr.io/rhuze-emryk/emryk-ml:latest` for NVIDIA systems
- `ghcr.io/rhuze-emryk/emryk-ml-intel:latest` for Intel iGPU systems

Choose the variant matching the hardware. The NVIDIA image includes the open
driver stack and rootless-container CDI metadata. The Intel image deliberately
omits that stack and the nouveau blacklist. Both include KDE, Tailscale,
Cockpit, Podman/Distrobox, signature policy, staged updates, SSH hardening, and
the same restrictive default firewall files.

## What operators should expect

- Releases normally arrive weekly and are staged automatically without an
  unattended reboot.
- SSH and Cockpit are intended to be reached over Tailscale. The shipped public
  zone does not declare either service, while the `tailscale0` zone accepts
  tailnet traffic. Local networking changes can alter effective reachability.
- Rootless Podman is the default container API path. It reduces exposure from a
  root-owned daemon/socket but does not eliminate operating-system or runtime
  vulnerabilities.
- The hosted release gate boots both variants and checks the expected digest,
  SELinux, SSH, systemd, firewall, signature policy, and variant boundary.
  Physical NVIDIA execution remains a separate hardware-canary task.

## Verification evidence

Each published digest has three complementary, independently inspectable
artifacts: an Emryk-key signature, GitHub OIDC build provenance, and an attested
CycloneDX RPM-database inventory. They have different scope and trust roots;
none is a substitute for reviewing the threat model.

Use the exact signature and attestation commands in [README.md](README.md).
The SBOM covers RPM database contents plus explicitly reviewed non-RPM helper
exceptions; it is not a claim about every file or every dependency installed by
applications after boot.

## Support handoff

For routine update status, collect `bootc status --json` and the booted digest.
For boot failures, preserve the previous deployment and use `bootc rollback`.
For suspected vulnerabilities, use the private reporting routes in
[SECURITY.md](SECURITY.md). For signer compromise, stop normal publication and
follow [KEY-POLICY.md](KEY-POLICY.md); hosts predating the recovery bootstrap
need manual recovery.
