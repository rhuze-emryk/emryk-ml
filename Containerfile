FROM scratch AS ctx
COPY build_files /

FROM ghcr.io/ublue-os/akmods-nvidia-open:main-44-7.0.4-200.fc44.x86_64 AS nvidia

FROM ghcr.io/ublue-os/kinoite-main:latest

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

RUN bootc container lint
