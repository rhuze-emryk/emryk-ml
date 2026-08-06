#!/bin/bash
# Write or clear the staged-update login nudge. Parsing failures clear the
# nudge instead of turning an informational timer into an operational failure.
set -uo pipefail

readonly MOTD=/run/motd.d/95-emryk-update.motd

status_json=$(bootc status --json 2>/dev/null) || {
    rm -f "$MOTD"
    exit 0
}

parsed=$(printf '%s' "$status_json" | python3 -c '
import json
import sys

try:
    document = json.load(sys.stdin)
except Exception:
    print("no  ")
    sys.exit(0)

staged = (document.get("status") or {}).get("staged")
if not staged:
    print("no  ")
    sys.exit(0)

ostree = staged.get("ostree") or {}
serial = ostree.get("deploySerial")
print("yes", ostree.get("checksum") or "", "" if serial is None else serial)
' 2>/dev/null) || {
    rm -f "$MOTD"
    exit 0
}

read -r has_staged checksum serial <<<"$parsed"
if [[ ${has_staged:-no} != yes ]]; then
    rm -f "$MOTD"
    exit 0
fi

running_kver=$(uname -r)
staged_kver=""
if [[ -n ${checksum:-} ]]; then
    for moddir in /ostree/deploy/*/deploy/"${checksum}.${serial:-0}"/usr/lib/modules/*/; do
        [[ -d $moddir ]] || continue
        kver=${moddir%/}
        kver=${kver##*/}
        [[ $kver == "$running_kver" ]] || staged_kver=$kver
    done
fi

mkdir -p /run/motd.d
{
    echo
    echo "  *** A system update has been downloaded and staged. ***"
    if [[ -n $staged_kver ]]; then
        echo "      It includes a new kernel (${running_kver} -> ${staged_kver});"
        echo "      the NVIDIA driver reloads on reboot."
    fi
    echo "      Reboot when convenient to apply it:  sudo systemctl reboot"
    echo "      Nothing reboots on its own; running jobs are safe until you do."
    echo
} > "$MOTD"
