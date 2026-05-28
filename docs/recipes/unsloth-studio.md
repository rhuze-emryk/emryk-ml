# Unsloth Studio (rootless)

Earlier builds of the `:latest-private-ml` variant shipped Unsloth Studio as a rootful Quadlet that auto-started on demand. That setup pulled `docker.io/unsloth/unsloth:latest` as root and exposed the no-auth Studio UI on a loopback port. We removed it because the trade-off — convenience versus running a moving-tag, unauthenticated, root-owned container on every Emryk Workstation that installed the variant — was the wrong shape for an image whose stated principle is *closed by default*.

This recipe is the supported replacement: a rootless container, started by you, scoped to your user.

## What you get

- Studio reachable at `http://127.0.0.1:8888/`.
- Container runs under your user — not root.
- GPU passed through via CDI. No `--privileged`, no rootful socket.
- Studio state persists in a named volume.

## Prerequisites

The image already provides everything you need:

| Component | Where it's set up |
|---|---|
| `nvidia-container-toolkit` | installed in `:latest-private-ml` (`build_files/private-ml-install.sh`) |
| `/etc/cdi/nvidia.yaml` | regenerated at every boot by `nvidia-cdi-generate.service` |
| Rootless `podman.socket` | enabled globally (`build_files/build.sh`) |

Quick sanity check:

```bash
test -f /etc/cdi/nvidia.yaml && echo "CDI spec present"
systemctl --user is-enabled podman.socket
```

## Run it

```bash
podman run --rm -d \
    --name unsloth-studio \
    --device nvidia.com/gpu=all \
    --publish 127.0.0.1:8888:8888 \
    --volume unsloth-studio-data:/root \
    docker.io/unsloth/unsloth:latest \
    unsloth studio -H 0.0.0.0 -p 8888

xdg-open http://127.0.0.1:8888/
```

The first run is slow because Podman pulls the multi-GB image. After that it's cached on local storage.

## Stop it

```bash
podman stop unsloth-studio
```

`--rm` in the run command means the container is removed on stop; the `unsloth-studio-data` named volume is retained, so your state survives.

## Pin the image (recommended)

`:latest` is a moving tag. To pin to an immutable digest:

```bash
podman pull docker.io/unsloth/unsloth:latest
podman inspect --format '{{.Digest}}' docker.io/unsloth/unsloth:latest
# Substitute the resulting sha256:... into your run command:
#   docker.io/unsloth/unsloth@sha256:...
```

Update the pin deliberately when you want to take a new version, the same way you would for any other dependency.

## Auto-start on login (optional)

If you used the old desktop entry to launch Studio, the equivalent rootless drop-in lives in your home directory — nothing in the base image changes.

Save as `~/.config/containers/systemd/unsloth-studio.container`, then run `systemctl --user daemon-reload`:

```ini
[Unit]
Description=Unsloth Studio (rootless)
After=default.target

[Container]
Image=docker.io/unsloth/unsloth:latest
ContainerName=unsloth-studio
AddDevice=nvidia.com/gpu=all
PublishPort=127.0.0.1:8888:8888
Volume=unsloth-studio-data:/root
Exec=unsloth studio -H 0.0.0.0 -p 8888

[Service]
Restart=on-failure

[Install]
WantedBy=default.target
```

`systemctl --user enable --now unsloth-studio.service` will start it under your user session.

## What this does *not* protect against

- **Unsloth Studio still has no authentication.** Binding to `127.0.0.1` keeps it off your tailnet and LAN, but any process running as your user on this host can reach it. If you don't trust everything running under your user, don't run Studio.
- **Image provenance.** `docker.io/unsloth/unsloth` is not signed by Emryk and not covered by our cosign policy. You are trusting Docker Hub and the Unsloth project for this container. Pinning to a digest (above) is the mitigation.
- **GPU-side isolation.** Side channels between processes sharing the GPU are not addressed by the rootless boundary.
