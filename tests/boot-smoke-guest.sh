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
# Name the failing check. Most assertions below are bare test expressions
# that exit silently under set -e; without this the only evidence is the
# journal dump (2026-11-01 F45 publish: an hour to find a grep).
trap 'echo >&2 "smoke check failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

work_dir=$(mktemp -d /tmp/emryk-boot-smoke.XXXXXXXX)
trap 'rm -rf -- "$work_dir"' RETURN

# The serial login prompt can appear before multi-user.target finishes
# starting (slow under software emulation). Wait briefly for readiness so the
# guest checks do not race the boot.
for _ in {1..90}; do
    systemctl is-active --quiet multi-user.target && break
    sleep 2
done
systemctl is-active --quiet multi-user.target
# Informational: "kvm" when the runner gave QEMU hardware acceleration,
# "qemu" when it fell back to TCG software emulation.
echo "virtualization: $(systemd-detect-virt || true)"

bootc status --json > "$work_dir/bootc-status.json"
jq -e --arg digest "$expected_digest" \
    '.. | strings | select(. == $digest)' "$work_dir/bootc-status.json" >/dev/null
grep -Fq "$expected_image" "$work_dir/bootc-status.json"

[[ $(getenforce) == Enforcing ]]

# Restricted ptrace (F45 default, enforced by build.sh removing the override
# package). Guard against a future dnf5 install pulling it back in via a
# Recommends. Written as an if, not `! rpm -q`: set -e ignores `!` lines.
[[ $(sysctl -n kernel.yama.ptrace_scope) == 1 ]]
if rpm -q yama-ptrace-enable >/dev/null 2>&1; then
    echo >&2 'yama-ptrace-enable is installed; ptrace_scope would revert to 0 on the next boot'
    exit 1
fi

sshd -t
sshd -T -C user=ci-smoke,host=localhost,addr=127.0.0.1 \
    > "$work_dir/sshd-effective.txt"
# Case-insensitive: OpenSSH <= 9.x printed `sshd -T` keywords lowercased,
# OpenSSH 10.5 (Fedora 45) prints them in canonical CamelCase.
grep -Eiq '^permitrootlogin no$' "$work_dir/sshd-effective.txt"
grep -Eiq '^passwordauthentication no$' "$work_dir/sshd-effective.txt"
grep -Eiq '^kbdinteractiveauthentication no$' "$work_dir/sshd-effective.txt"
grep -Eiq '^permitemptypasswords no$' "$work_dir/sshd-effective.txt"

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

# The real protection test. OS updates go through ostree's container importer
# with /etc/containers/policy.json, whether the deployment's origin says
# ostree-image-signed or ostree-unverified-registry (bootc 1.16: the latter
# only skips a pre-flight check on the policy default). At this point in the
# release the staged digest this VM booted from is NOT yet signed, so the
# guest's own policy must refuse to pull it, with a signature error rather
# than a network one. This exercises the exact code path `bootc upgrade` uses.
sig_repo="$work_dir/sigcheck-repo"
ostree --repo="$sig_repo" init --mode=bare-user
if pull_output=$(ostree container image pull "$sig_repo" \
    "ostree-unverified-registry:${expected_source}" 2>&1); then
    echo >&2 "host policy ACCEPTED an unsigned image: ${expected_source}"
    exit 1
fi
grep -Fq 'A signature was required, but no signature exists' <<<"$pull_output" || {
    echo >&2 "unsigned pull failed for the wrong reason: ${pull_output}"
    exit 1
}

jq empty /etc/containers/policy.json
jq -e '.default == [{"type": "reject"}]' /etc/containers/policy.json >/dev/null
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

# systemctl does not accept a unit pattern after bare --failed (it reads the
# unit name as a command verb and errors on stderr with empty stdout), which
# made the previous grep-based form pass unconditionally. is-failed exits 0
# only when the unit is actually in the failed state.
for unit in "${essential_units[@]}" emryk-install-flatpaks.service; do
    if systemctl is-failed --quiet "$unit"; then
        echo >&2 "essential unit failed: $unit"
        exit 1
    fi
done

case "$variant" in
    nvidia)
        modinfo nvidia >/dev/null
        command -v nvidia-ctk >/dev/null
        # Upstream akmods retired ublue-nvctk-cdi.service (Aug 2026) for
        # nvidia-container-toolkit's own nvidia-cdi-refresh.service.
        systemctl is-enabled --quiet nvidia-cdi-refresh.service
        # The Emryk start-limit drop-ins must be in effect: without them a
        # GPU-less boot never reaches multi-user.target (restart loop), which
        # is what the wait at the top of this script would have caught.
        for unit in nvidia-cdi-refresh.service nvidia-persistenced.service; do
            [[ $(systemctl show -p StartLimitIntervalUSec --value "$unit") == 2min ]] || {
                echo >&2 "start-limit drop-in not applied: $unit"
                exit 1
            }
            [[ $(systemctl show -p StartLimitBurst --value "$unit") == 5 ]]
        done
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
        # Capture, don't `grep -q` inside `if`: with pipefail, grep -q exiting
        # early kills rpm with SIGPIPE (status 141), the `if` swallows it and
        # the check passed vacuously. The old `kmod` alternative also matched
        # Fedora's plain kmod/kmod-libs, which every image ships.
        nvidia_pkgs=$(rpm -qa | grep -E '^(akmods?-|akmods$|kmod-nvidia|xorg-x11-drv-nvidia|nvidia-container)' || true)
        if [[ -n $nvidia_pkgs ]]; then
            echo >&2 "Intel image contains NVIDIA driver-stack package(s): ${nvidia_pkgs//$'\n'/ }"
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
