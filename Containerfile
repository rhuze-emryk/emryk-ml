FROM scratch AS ctx
COPY build_files /
# Active cosign public key. build.sh installs it for runtime verification of
# future pulls. The offline recovery public key is installed alongside it once
# recovery-cosign.pub has been supplied by the offline key custodian.
COPY cosign.pub /cosign.pub

# Base images are pinned by digest so an upstream tag rewrite cannot silently
# change what we build. The tag is kept for readability; the digest is what
# the build pulls. A pin alone does not prove origin: build.yml checks
# Universal Blue's cosign signature on each digest (upstream-keys/) first.
# Bump tag and digest together when intentionally rolling forward.
FROM ghcr.io/ublue-os/akmods-nvidia-open:main-44-7.2.13-200.fc44.x86_64@sha256:8183d4a320d36214b076368040744fe93e5dbb43bee40eccd1b9ea91117306fb AS akmods

# kinoite-main tracks the Fedora major (:44), not :latest. Upstream moves
# :latest to a new Fedora release a few weeks after it ships, and Renovate
# would deliver that as an auto-merged "digest" refresh. A Fedora major move
# must be a deliberate PR that bumps this tag and the akmods -44- tag together;
# upstream-release-watch.yml opens an issue when :latest moves past this pin.
FROM ghcr.io/ublue-os/kinoite-main:44@sha256:88fff5bdc7b39ad5990c9bef6e3fee862646c30944528f300bb118bcbf6f6f46 AS kinoite

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

# Without a GPU (release-gate VM, or hardware where the driver cannot bind)
# nvidia-cdi-refresh.service and nvidia-persistenced.service restart forever:
# upstream's 5-per-10s start limit never trips when one attempt takes >2 s,
# and multi-user.target is implicitly After= both, so it never activates.
# Count the same 5 attempts over 2 min instead. See the drop-ins for detail.
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    install -D -m 0644 \
    /ctx/systemd/nvidia-cdi-refresh.service.d/20-emryk-start-limit.conf \
    /etc/systemd/system/nvidia-cdi-refresh.service.d/20-emryk-start-limit.conf && \
    install -D -m 0644 \
    /ctx/systemd/nvidia-persistenced.service.d/20-emryk-start-limit.conf \
    /etc/systemd/system/nvidia-persistenced.service.d/20-emryk-start-limit.conf

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
