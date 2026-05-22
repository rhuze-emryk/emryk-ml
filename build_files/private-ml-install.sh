#!/bin/bash

set -ouex pipefail

# ---------------------------------------------------------------------------
# Mullvad VPN
# Official Fedora repo. The repo file ships gpgcheck=1 + gpgkey URL, so the
# package signature is verified against Mullvad's published key.
# Ref: https://mullvad.net/en/help/install-mullvad-app-linux
# ---------------------------------------------------------------------------
curl -fsSL https://repository.mullvad.net/rpm/stable/mullvad.repo \
    -o /etc/yum.repos.d/mullvad.repo

# ---------------------------------------------------------------------------
# NVIDIA Container Toolkit
# Required so Podman can pass the host GPU into containers via CDI. The CDI
# spec itself is generated at first boot (see nvidia-cdi-generate.service)
# because nvidia-ctk has to inspect the live kernel modules.
# ---------------------------------------------------------------------------
curl -fsSL https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \
    -o /etc/yum.repos.d/nvidia-container-toolkit.repo

dnf5 install -y \
    mullvad-vpn \
    nvidia-container-toolkit

# ---------------------------------------------------------------------------
# Unsloth Studio — Podman Quadlet unit
# On-demand only: no [Install] section, so it does NOT auto-start at boot.
# The "Start Unsloth Studio" desktop entry launches it.
# Port is bound to 127.0.0.1 only — Studio has no auth and must not be
# reachable from the LAN by default.
# ---------------------------------------------------------------------------
mkdir -p /etc/containers/systemd
cat > /etc/containers/systemd/unsloth-studio.container <<'EOF'
[Unit]
Description=Unsloth Studio (no-code LLM fine-tuning UI)
Documentation=https://unsloth.ai/docs/new/studio
After=network-online.target nvidia-cdi-generate.service
Wants=network-online.target
Requires=nvidia-cdi-generate.service

[Container]
Image=docker.io/unsloth/unsloth:latest
ContainerName=unsloth-studio
AddDevice=nvidia.com/gpu=all
PublishPort=127.0.0.1:8888:8888
Volume=unsloth-studio-data:/root
Exec=unsloth studio -H 0.0.0.0 -p 8888

[Service]
Restart=on-failure
TimeoutStartSec=900
EOF

# ---------------------------------------------------------------------------
# NVIDIA CDI spec generator
# Runs at every boot so the spec stays in sync with the running driver after
# a base-image rebase. nvidia-ctk inspects loaded modules, so this can only
# run on a live system — not at image build time.
# ---------------------------------------------------------------------------
cat > /etc/systemd/system/nvidia-cdi-generate.service <<'EOF'
[Unit]
Description=Generate NVIDIA CDI spec for Podman GPU passthrough
Documentation=https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/cdi-support.html
After=local-fs.target

[Service]
Type=oneshot
ExecStartPre=/usr/bin/mkdir -p /etc/cdi
ExecStart=/usr/bin/nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# ---------------------------------------------------------------------------
# Desktop launcher
# /usr/libexec/emryk already exists (created by build.sh in the base image).
# ---------------------------------------------------------------------------
mkdir -p /usr/libexec/emryk
cat > /usr/libexec/emryk/launch-unsloth-studio.sh <<'EOF'
#!/bin/bash
set -euo pipefail

# Idempotent — systemctl start on a running unit is a no-op.
# Polkit rule (50-unsloth-studio.rules) lets wheel-group users run this
# without a root password prompt.
systemctl start unsloth-studio.service

# First start can be slow because Podman is pulling unsloth/unsloth (multi-GB).
# Poll for up to 5 minutes before giving up and opening the browser anyway.
for _ in $(seq 1 300); do
    if curl -sfL --max-time 1 http://127.0.0.1:8888/ >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

xdg-open http://127.0.0.1:8888/ >/dev/null 2>&1 &
EOF
chmod +x /usr/libexec/emryk/launch-unsloth-studio.sh

cat > /usr/share/applications/unsloth-studio.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Unsloth Studio
Comment=Start Unsloth Studio and open it in the browser
Exec=/usr/libexec/emryk/launch-unsloth-studio.sh
Icon=applications-science
Terminal=false
Categories=Development;Science;
Keywords=AI;ML;LLM;Unsloth;fine-tuning;
StartupNotify=true
EOF

# ---------------------------------------------------------------------------
# Polkit: allow wheel group to start/stop just unsloth-studio.service
# without a password. Scoped narrowly — does NOT grant blanket systemctl
# access.
# ---------------------------------------------------------------------------
mkdir -p /etc/polkit-1/rules.d
cat > /etc/polkit-1/rules.d/50-unsloth-studio.rules <<'EOF'
polkit.addRule(function(action, subject) {
    if (action.id == "org.freedesktop.systemd1.manage-units" &&
        subject.isInGroup("wheel")) {
        var unit = action.lookup("unit");
        if (unit == "unsloth-studio.service") {
            return polkit.Result.YES;
        }
    }
});
EOF

# ---------------------------------------------------------------------------
# Enable services
# Mullvad daemon runs at boot (user still has to log in once with their
# account number). CDI generator runs once per boot before Unsloth Studio
# is launched.
# ---------------------------------------------------------------------------
systemctl enable \
    mullvad-daemon.service \
    nvidia-cdi-generate.service
