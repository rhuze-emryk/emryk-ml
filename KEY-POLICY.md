# Signing-key and recovery policy

This policy covers the long-lived key used to authorize Emryk container
digests. GitHub OIDC provenance/SBOM attestations use a separate identity and do
not replace the container signer.

## Roles and custody

| Role | Private-key custody | Public-key location | Purpose |
|---|---|---|---|
| Active signer | Encrypted `SIGNING_SECRET` in the protected `production-signing` environment; password in separate `SIGNING_PASSWORD` | `cosign.pub` and `/etc/pki/containers/rhuze-emryk.pub` | Routine approved releases |
| Offline recovery signer | Encrypted removable/offline storage controlled by the maintainer; never GitHub, the repository, Codex, CI, or a normal workstation | `recovery-cosign.pub` and `/etc/pki/containers/rhuze-emryk-recovery.pub` after bootstrap | Recover from active-key compromise and preserve a permanent trust anchor |

Only public halves, fingerprints, and hashes may enter review. Never paste a
private key or passphrase into an issue, pull request, shell transcript,
workspace, AI prompt, CI artifact, or chat.

The offline recovery public key has not yet been supplied. Until the bootstrap
below is complete, hosts trust only the active key and active-key compromise is
a manual-recovery event. This is a P0 risk, not an implied capability.

## Policy semantics

Alternative trusted signers are expressed by one `sigstoreSigned` requirement
with a `keyPaths` array:

```json
{
  "type": "sigstoreSigned",
  "keyPaths": [
    "/etc/pki/containers/rhuze-emryk.pub",
    "/etc/pki/containers/rhuze-emryk-recovery.pub"
  ],
  "signedIdentity": { "type": "matchRepository" }
}
```

Do not create one requirement per key. Requirements in the policy array are
cumulative, so that shape would require every signature instead of accepting
any trusted signer.

## One-time recovery bootstrap

The offline custodian performs these steps without exposing private material to
the repository workspace:

1. On an offline machine, generate a new encrypted cosign key pair with a unique
   passphrase and create two tested backup copies of the encrypted private key.
2. Transfer only the public half into this repository as `recovery-cosign.pub`.
   Record and independently compare its SHA-256 and public-key fingerprint.
3. Update the image build to install it as
   `/etc/pki/containers/rhuze-emryk-recovery.pub`, add that path to the existing
   `keyPaths`, and require both variant smoke legs to find both paths.
4. Publish the resulting transition image with the still-trusted active key.
5. Collect digest-qualified `bootc status --json` evidence that every managed
   host has actually booted this transition image. A staged deployment or a
   waiting period is insufficient.
6. Mark pre-bootstrap/unobserved hosts as manual-recovery cases. The recovery
   key remains trusted in all later normal images.

## Planned active-key rotation

A yearly review is the target cadence, but rotation must not be described as
operational until the rehearsal gate below has passed and been recorded.

1. Generate an encrypted next-active key offline. Move only its public half into
   a reviewed transition change.
2. Publish an old-active-key-signed transition image whose single `keyPaths`
   requirement trusts old active, next active, and recovery public keys.
3. Confirm every managed host has booted the exact transition digest. Fleet
   management records must identify host, observed booted digest, and time.
4. Replace `SIGNING_SECRET` and `SIGNING_PASSWORD` in the protected environment
   with the next-active encrypted key and password. Do not weaken environment
   reviewers or branch restrictions during this change.
5. Dispatch a release. It must sign with the new active key, verify against the
   newly committed active public key, pass both VM legs, and only then promote.
6. Publish a new-active-key-signed cleanup image that keeps new active plus
   recovery and removes old active. Remove old trust only after fleet evidence
   proves every managed host has booted a deployment that trusts the new key.
7. Archive the retired encrypted private key offline according to incident and
   audit needs; remove it from active GitHub secrets.

## Incident recovery

Assume the active private key is compromised when its confidentiality or
passphrase separation cannot be demonstrated.

1. Freeze normal publishing and deny pending `production-signing` deployments.
   Preserve Actions, registry, environment, and access logs.
2. Generate a fresh encrypted active key offline and commit only its public
   half in an incident change.
3. Build an isolated candidate whose trust set contains fresh active plus the
   permanent recovery key and excludes the compromised active key. Both exact
   staged digests must pass scan and hosted VM boot gates.
4. On the controlled recovery machine, authenticate to GHCR, set
   `RECOVERY_PRIVATE_KEY` to the encrypted private key outside the repository,
   obtain `COSIGN_PASSWORD` interactively without logging it, and run:

   ```bash
   scripts/offline-recovery-release.sh \
     ghcr.io/rhuze-emryk/emryk-ml@sha256:INCIDENT_DIGEST \
     latest YYYYMMDD latest.YYYYMMDD
   ```

   Repeat for the Intel digest. The script signs with the offline key, verifies
   against the committed recovery public key using the repository's pinned
   cosign v3.0.6 attachment mode, and promotes only after verification.
5. Confirm booted digest evidence from recovery-enabled hosts. Use console or a
   known-good deployment for hosts predating the bootstrap.
6. Replace the protected active secrets with the fresh key, review the incident
   root cause, and resume normal publishing only after containment.

## Rehearsal gate

`tests/rehearse-key-rotation.sh` generates encrypted ephemeral
old/next/recovery/fresh/unrelated keys and uses a disposable registry to prove:

- old, next, and recovery signatures each work independently during transition;
- unsigned and unrelated-key images fail;
- recovery and fresh signatures work after incident rotation; and
- the removed old signer fails after incident rotation.

That cryptographic harness is necessary but not sufficient. A complete recorded
rehearsal also publishes disposable transition and incident candidates through
the two-variant VM boot gate, observes a booted transition digest before secret
replacement, and verifies the final cleanup trust set. Do not close the P0 risk
or claim the annual procedure is operational until both parts pass.

Keyless signing remains a separate evaluation. Any proposal must preserve an
offline recovery route, constrain workload identity narrowly, work with host
pull policy, and rehearse rollback before changing this policy.
