#!/bin/bash
set -euo pipefail

readonly expected_source=${1:?expected digest-qualified source is required}
readonly variant=${2:?variant is required}
readonly expected_digest=${expected_source##*@}
readonly expected_image=${expected_source%@*}

diagnose() {
    local exit_code=$?
    if ((exit_code == 0)); then
        return
    fi
    echo "EMRYK_JOURNAL_BEGIN"
    systemctl --failed --no-legend --plain || true
    journalctl -b --no-pager -n 1000 || true
    echo "EMRYK_JOURNAL_END"
    echo "EMRYK_SMOKE_FAILED:${exit_code}"
    exit "$exit_code"
}
trap diagnose EXIT

work_dir=$(mktemp -d /tmp/emryk-boot-smoke.XXXXXXXX)
trap 'rm -rf -- "$work_dir"' RETURN

systemctl is-active --quiet multi-user.target

bootc status --json > "$work_dir/bootc-status.json"
jq -e --arg digest "$expected_digest" \
    '.. | strings | select(. == $digest)' "$work_dir/bootc-status.json" >/dev/null
grep -Fq "$expected_image" "$work_dir/bootc-status.json"

[[ $(getenforce) == Enforcing ]]

sshd -t
sshd -T -C user=ci-smoke,host=localhost,addr=127.0.0.1 \
    > "$work_dir/sshd-effective.txt"
grep -Eq '^permitrootlogin no$' "$work_dir/sshd-effective.txt"
grep -Eq '^passwordauthentication no$' "$work_dir/sshd-effective.txt"
grep -Eq '^kbdinteractiveauthentication no$' "$work_dir/sshd-effective.txt"
grep -Eq '^permitemptypasswords no$' "$work_dir/sshd-effective.txt"

essential_units=(
    sshd.service
    tailscaled.service
    cockpit.socket
    bootc-fetch-apply-updates.timer
    emryk-update-nudge.timer
)
unit_files=()
for unit in "${essential_units[@]}"; do
    systemctl is-enabled --quiet "$unit"
    fragment=$(systemctl show --property=FragmentPath --value "$unit")
    [[ -f $fragment ]]
    unit_files+=("$fragment")
done
systemd-analyze verify "${unit_files[@]}"

public_services=$(firewall-offline-cmd --zone=public --list-services)
[[ " $public_services " != *' ssh '* ]]
[[ " $public_services " != *' cockpit '* ]]
public_ports=$(firewall-offline-cmd --zone=public --list-ports)
[[ " $public_ports " != *' 22/tcp '* ]]
[[ " $public_ports " != *' 9090/tcp '* ]]
[[ -z $(firewall-offline-cmd --zone=public --list-rich-rules) ]]
grep -Eq '<interface[[:space:]]+name="tailscale0"[[:space:]]*/>' \
    /etc/firewalld/zones/tailscale.xml

jq empty /etc/containers/policy.json
mapfile -t key_paths < <(jq -r '
    [.. | objects | select(.type? == "sigstoreSigned") | .keyPaths[]?] | unique[]
' /etc/containers/policy.json)
(( ${#key_paths[@]} > 0 ))
for key_path in "${key_paths[@]}"; do
    [[ -s $key_path ]]
done

flatpak_unit=/etc/systemd/system/emryk-install-flatpaks.service
[[ -f $flatpak_unit ]]
[[ -L /etc/systemd/system/multi-user.target.wants/emryk-install-flatpaks.service ]]
systemd-analyze verify "$flatpak_unit"
[[ $(systemctl is-enabled emryk-install-flatpaks.service) == masked-runtime ]]

for unit in "${essential_units[@]}" emryk-install-flatpaks.service; do
    if systemctl --failed --no-legend --plain "$unit" | grep -q .; then
        echo >&2 "essential unit failed: $unit"
        exit 1
    fi
done

case "$variant" in
    nvidia)
        modinfo nvidia >/dev/null
        command -v nvidia-ctk >/dev/null
        systemctl cat ublue-nvctk-cdi.service >/dev/null
        ;;
    intel)
        if modinfo nvidia >/dev/null 2>&1; then
            echo >&2 'Intel image contains NVIDIA module metadata.'
            exit 1
        fi
        if rpm -q nvidia-container-toolkit >/dev/null 2>&1; then
            echo >&2 'Intel image contains NVIDIA Container Toolkit.'
            exit 1
        fi
        if rpm -qa | grep -Eq '^(akmod|kmod|xorg-x11-drv-nvidia|nvidia-container)'; then
            echo >&2 'Intel image contains an NVIDIA driver-stack package.'
            exit 1
        fi
        [[ ! -e /usr/lib/modprobe.d/blacklist-nouveau.conf ]]
        ;;
    *)
        echo >&2 "unknown variant: $variant"
        exit 2
        ;;
esac

trap - EXIT
rm -rf -- "$work_dir"
echo EMRYK_SMOKE_OK
