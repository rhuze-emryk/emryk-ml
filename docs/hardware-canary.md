# NVIDIA hardware-canary runbook

Hosted VM smoke tests have no physical GPU. Use this runbook on an approved,
non-production NVIDIA canary before treating a release as physically validated.
Record the host identifier, booted image digest, GPU model, Secure Boot state,
kernel, and command results with the release run.

1. Boot the exact digest that passed the hosted `nvidia` smoke leg and confirm
   `bootc status --json` identifies it as the booted deployment.
2. Confirm the expected modules are loaded and not tainted by a version mismatch:

   ```bash
   uname -r
   modinfo nvidia | sed -n '1,20p'
   lsmod | grep -E '^nvidia(_drm|_modeset|_uvm)?\b'
   journalctl -b -k --no-pager | grep -Ei 'nvidia|nouveau|module verification'
   ```

3. Exercise the driver and enumerate the device:

   ```bash
   nvidia-smi
   nvidia-smi --query-gpu=name,uuid,driver_version --format=csv
   ```

4. Confirm boot-time CDI generation succeeded and the document parses:

   ```bash
   systemctl status --no-pager ublue-nvctk-cdi.service
   sudo nvidia-ctk cdi list
   sudo test -s /etc/cdi/nvidia.yaml
   ```

5. As an unprivileged user, run a minimal rootless Podman GPU workload without
   `sudo` or `--privileged`:

   ```bash
   podman info --format '{{.Host.Security.Rootless}}'
   podman run --rm --device nvidia.com/gpu=all \
     docker.io/nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi
   ```

6. Reboot once more and repeat `nvidia-smi` and the rootless workload to catch
   one-shot CDI or module-ordering defects.

Any module load failure, `nvidia-smi` error, missing CDI device, SELinux denial,
or need for rootful/privileged execution fails the canary. Keep the prior
release tag in service and investigate; do not reinterpret the hosted metadata
check as hardware evidence.
