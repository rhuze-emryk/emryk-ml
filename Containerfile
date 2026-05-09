FROM scratch AS ctx
COPY build_files /

FROM ghcr.io/ublue-os/akmods-nvidia-open:latest AS nvidia

FROM ghcr.io/ublue-os/kinoite-main:latest

# dnf5 resolves user-space NVIDIA driver deps (xorg DDX, libGL, etc.) from RPMFusion
# automatically when the kernel module RPMs are installed — no explicit list needed here.
RUN --mount=type=bind,from=nvidia,source=/rpms,target=/tmp/rpms \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    find /tmp/rpms -name '*.rpm' ! -name '*.src.rpm' ! -name '*debug*' | \
    sort | xargs dnf5 install -y

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build.sh

RUN bootc container lint
