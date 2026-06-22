FROM scratch AS ctx
COPY build_files /
# Public cosign key — build.sh drops a copy at /etc/pki/containers/ for
# runtime signature verification of future pulls (SECURITY-TODO #2).
COPY cosign.pub /cosign.pub

# Base images are pinned by digest so an upstream tag rewrite cannot silently
# change what we build. The tag is kept for readability; the digest is what
# the runtime verifies. Bump both together when intentionally rolling forward.
FROM ghcr.io/ublue-os/akmods-nvidia-open:main-44-7.0.12-201.fc44.x86_64@sha256:6cc854bed43eb6eedac000a2978eb97337cd371af0d3e66a9b8f000186b18d29 AS nvidia

FROM ghcr.io/ublue-os/kinoite-main:latest@sha256:3b80c7a9a1894e4e7503b19860ee87dafcb86f4644108688ca418c195a52f554

# nvidia-install.sh: installs kmod + full driver stack, sets up repos, fixes dracut for
# forced driver load (prevents black screen on boot), installs SELinux policy for
# nvidia-container. IMAGE_NAME=kinoite adds supergfxctl for dual-GPU switching.
RUN --mount=type=bind,from=nvidia,source=/rpms,target=/tmp/akmods-rpms \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    IMAGE_NAME=kinoite bash /tmp/akmods-rpms/ublue-os/nvidia-install.sh

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
