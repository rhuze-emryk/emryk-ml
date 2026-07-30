FROM scratch AS ctx
COPY build_files /
# Public cosign key — build.sh drops a copy at /etc/pki/containers/ for
# runtime signature verification of future pulls (SECURITY-TODO #2).
COPY cosign.pub /cosign.pub

# Base images are pinned by digest so an upstream tag rewrite cannot silently
# change what we build. The tag is kept for readability; the digest is what
# the runtime verifies. Bump both together when intentionally rolling forward.
FROM ghcr.io/ublue-os/akmods-nvidia-open:main-44-7.0.14-201.fc44.x86_64@sha256:b523ce150646722ab57aecdb54269451397ad03362d16fa3a483e49637da4331 AS akmods

FROM ghcr.io/ublue-os/kinoite-main:latest@sha256:32c1e4f811eae5e00394f8716afc51030b34802b44ff51f507fff9ccff10bfba AS kinoite

# ---------------------------------------------------------------------------
# intel: laptop/iGPU variant (published as emryk-ml-intel). Same payload and
# hardening as the NVIDIA image minus the driver stack — Intel iGPUs (mesa)
# and Secure Boot work with what the base already ships, no out-of-tree
# kmods. build.sh is shared verbatim: its one NVIDIA-ism, the nouveau
# blacklist, is a no-op on hardware with no NVIDIA GPU. Built with
# `--target intel`; the NVIDIA stage below stays last so it remains the
# default build target.
# ---------------------------------------------------------------------------
FROM kinoite AS intel

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build.sh

# SECURITY-TODO #3/#8: every payload file must be RPM-owned so the
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

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build.sh

# SECURITY-TODO #3/#8: every payload file must be RPM-owned so the
# RPM-only SBOM (build.yml syft step) captures it. Fails the build on
# any unowned file outside the script's allowlist.
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    bash /ctx/verify-payload-rpm-owned.sh

RUN bootc container lint
