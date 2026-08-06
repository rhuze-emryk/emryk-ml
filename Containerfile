FROM scratch AS ctx
COPY build_files /
# Active cosign public key. build.sh installs it for runtime verification of
# future pulls. The offline recovery public key is installed alongside it once
# recovery-cosign.pub has been supplied by the offline key custodian.
COPY cosign.pub /cosign.pub

# Base images are pinned by digest so an upstream tag rewrite cannot silently
# change what we build. The tag is kept for readability; the digest is what
# the runtime verifies. Bump both together when intentionally rolling forward.
FROM ghcr.io/ublue-os/akmods-nvidia-open:main-44-7.0.14-201.fc44.x86_64@sha256:b523ce150646722ab57aecdb54269451397ad03362d16fa3a483e49637da4331 AS akmods

FROM ghcr.io/ublue-os/kinoite-main:latest@sha256:6eebf2447d5350d07ebbb99bf402f96edb56053d68b06cf16c72ac78b24edff0 AS kinoite

# ---------------------------------------------------------------------------
# intel: laptop/iGPU variant (published as emryk-ml-intel). Same payload and
# hardening as the NVIDIA image minus the driver stack — Intel iGPUs (mesa)
# and Secure Boot work with what the base already ships, no out-of-tree
# kmods. The shared build payload contains no NVIDIA packages or module
# configuration. Built with `--target intel`; the NVIDIA stage below stays
# last so it remains the default build target.
# ---------------------------------------------------------------------------
FROM kinoite AS intel

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build.sh

# Every executable payload file must be RPM-owned so the
# RPM-only SBOM (build.yml syft step) captures it. Fails the build on
# any unowned file outside the script's allowlist.
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    bash /ctx/verify-payload-rpm-owned.sh

RUN bootc container lint

# ---------------------------------------------------------------------------
# nvidia: the original cloud ML workstation image (published as emryk-ml).
# Last stage = default target, so `podman build .` still produces it.
# ---------------------------------------------------------------------------
FROM kinoite AS nvidia

# nvidia-install.sh: installs kmod + full driver stack, sets up repos, fixes dracut for
# forced driver load (prevents black screen on boot), installs SELinux policy for
# nvidia-container. IMAGE_NAME=kinoite adds supergfxctl for dual-GPU switching.
#
# MULTILIB=0 (upstream knob, default 1) skips the 32-bit userland: six
# mesa-*.i686 packages plus the NVIDIA .i686 GL libs — ~50 RPMs that exist
# only so native 32-bit games can reach the GPU, which this image doesn't
# serve. It also removes this build's one recurring failure class: those
# i686 mesa packages came from the LIVE Fedora repos while their x86_64
# halves are baked into the digest-pinned base, and RPM's multilib version
# lock turns any upstream mesa release in between into a transaction
# failure (2026-06-05, 2026-06-22, 2026-07-06). No i686, no version lock,
# no skew. The base ships zero i686 packages, so nothing is left behind.
RUN --mount=type=bind,from=akmods,source=/rpms,target=/tmp/akmods-rpms \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    IMAGE_NAME=kinoite MULTILIB=0 bash /tmp/akmods-rpms/ublue-os/nvidia-install.sh

# nouveau must not claim the GPU before the NVIDIA driver. Keep this file in
# the NVIDIA stage: the Intel image must contain neither this blacklist nor
# any package from the NVIDIA akmods payload.
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    install -D -m 0644 /ctx/modprobe.d/blacklist-nouveau.conf \
    /usr/lib/modprobe.d/blacklist-nouveau.conf

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build.sh

# Every executable payload file must be RPM-owned so the
# RPM-only SBOM (build.yml syft step) captures it. Fails the build on
# any unowned file outside the script's allowlist.
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    bash /ctx/verify-payload-rpm-owned.sh

RUN bootc container lint
