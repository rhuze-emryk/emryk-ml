FROM scratch AS ctx
COPY build_files /
# Public cosign key — build.sh drops a copy at /etc/pki/containers/ for
# runtime signature verification of future pulls (SECURITY-TODO #2).
COPY cosign.pub /cosign.pub

# Base images are pinned by digest so an upstream tag rewrite cannot silently
# change what we build. The tag is kept for readability; the digest is what
# the runtime verifies. Bump both together when intentionally rolling forward.
FROM ghcr.io/ublue-os/akmods-nvidia-open:main-44-7.0.14-201.fc44.x86_64@sha256:0973a0fde052c5376721a697c0739b35fe202f2b6aae6535bacd29aada9f2682 AS nvidia

FROM ghcr.io/ublue-os/kinoite-main:latest@sha256:505caaae0901b97b37db2325c25a0946cfe2be59bda5c33980b2c1e3c92718fb

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
RUN --mount=type=bind,from=nvidia,source=/rpms,target=/tmp/akmods-rpms \
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
