#!/bin/bash

set -ouex pipefail

# Google Antigravity RPM repo. gpgcheck=0 matches Google's official Fedora
# instructions — their published Artifact Registry key currently fails signature
# verification on Fedora 44. Revisit when Google fixes RPM signing.
# Ref: https://antigravity.google/download/linux
cat > /etc/yum.repos.d/antigravity.repo <<'EOF'
[antigravity-rpm]
name=Antigravity RPM Repository
baseurl=https://us-central1-yum.pkg.dev/projects/antigravity-auto-updater-dev/antigravity-rpm
enabled=1
gpgcheck=0
EOF

dnf5 install -y antigravity
