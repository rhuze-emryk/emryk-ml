# Unsloth Studio (rootless)

Earlier builds shipped Unsloth Studio as a rootful Quadlet that auto-started on demand. That setup pulled `docker.io/unsloth/unsloth:latest` as root and exposed the no-auth Studio UI on a loopback port. We removed it because the trade-off — convenience versus running a moving-tag, unauthenticated, root-owned container on every Emryk Workstation that installed the variant — was the wrong shape for an image whose stated principle is *closed by default*.

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
| `nvidia-container-toolkit` | shipped on `:latest` (provided by upstream `ublue-os-nvidia-addons` via akmods) |
| `/etc/cdi/nvidia.yaml` | regenerated at every boot by `ublue-nvctk-cdi.service` (upstream `ublue-os-nvidia-addons`) |
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
    --publish 127.0.0.1:8888:8000 \
    --volume unsloth-studio-data:/workspace \
    docker.io/unsloth/unsloth:latest

xdg-open http://127.0.0.1:8888/
```

The first run is slow: Podman pulls the multi-GB image, then the container's entrypoint builds the Studio frontend and installs a flash-attn wheel before serving. After that it's cached on local storage.

**Why `8888:8000` and no trailing command?** This image is a multi-service container managed by its own `supervisord`: Studio listens on `8000`, a Jupyter Lab on `8888`, and `sshd` on `22`. The entrypoint always runs that supervisord, so any command you append (e.g. `unsloth studio …`) is **ignored** — Studio's port is fixed at `8000` inside the container. We publish only Studio, mapping it to host `8888` so the URL above is unchanged; Jupyter and `sshd` stay inside the container, unpublished and off your loopback, which keeps with *closed by default*.

> **First-time volume note.** The `unsloth-studio-data` volume must be **fresh** the first time it is mounted. Podman seeds an empty named volume from the image's `/workspace` (preserving the in-container `unsloth` user's ownership); a volume that was populated elsewhere — for example by an earlier version of this recipe that mounted it at `/root` — will *not* be re-seeded and Studio will crash-loop on startup. If you ran the old recipe, remove the stale volume once before starting: `podman volume rm unsloth-studio-data`.

## Stop it

```bash
podman stop unsloth-studio
```

`--rm` in the run command means the container is removed on stop; the `unsloth-studio-data` named volume is retained, so your state survives. The volume is mounted at `/workspace`, which holds Studio's database and outputs (`/workspace/studio/`) and the downloaded-model cache (`HF_HOME=/workspace/.cache/huggingface`) — so your trained adapters and pulled models persist across restarts.

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

[Container]
Image=docker.io/unsloth/unsloth:latest
ContainerName=unsloth-studio
AddDevice=nvidia.com/gpu=all
PublishPort=127.0.0.1:8888:8000
Volume=unsloth-studio-data:/workspace

[Service]
Restart=on-failure
# Multi-GB first pull from docker.io; default 90s is too short.
TimeoutStartSec=900

[Install]
WantedBy=default.target
```

`systemctl --user enable --now unsloth-studio.service` will start it under your user session.

## What this does *not* protect against

- **Unsloth Studio still has no authentication.** Binding to `127.0.0.1` keeps it off your tailnet and LAN, but any process running as your user on this host can reach it. If you don't trust everything running under your user, don't run Studio.
- **Bundled extra services.** The image also runs a Jupyter Lab (`8888`) and an `sshd` (`22`) inside the container. This recipe publishes neither — only Studio's `8000` is mapped to your loopback — so they are not reachable from the host. If you change the `--publish` flags, understand you may be exposing a notebook server and SSH along with Studio.
- **Image provenance.** `docker.io/unsloth/unsloth` is not signed by Emryk and not covered by our cosign policy. You are trusting Docker Hub and the Unsloth project for this container. Pinning to a digest (above) is the mitigation.
- **GPU-side isolation.** Side channels between processes sharing the GPU are not addressed by the rootless boundary.
