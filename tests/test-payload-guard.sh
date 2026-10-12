#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
guard=${repo_root}/build_files/verify-payload-rpm-owned.sh
mock_rpm=${repo_root}/tests/fixtures/rpm-unowned.sh

"$guard" --is-allowlisted /usr/libexec/emryk/install-flatpaks.sh
"$guard" --is-allowlisted /usr/libexec/emryk/update-nudge.sh

if "$guard" --is-allowlisted /usr/libexec/emryk/arbitrary; then
    echo >&2 "broad Emryk payload exception returned"
    exit 1
fi

if "$guard" --is-allowlisted /usr/libexec/emryk/subdir/update-nudge.sh; then
    echo >&2 "nested Emryk payload exception returned"
    exit 1
fi

fixture_root=$(mktemp -d "${TMPDIR:-/tmp}/emryk-payload-test.XXXXXXXX")
trap 'rm -rf -- "$fixture_root"' EXIT
mkdir -p "$fixture_root/usr/libexec/emryk"
touch "$fixture_root/usr/libexec/emryk/install-flatpaks.sh"
touch "$fixture_root/usr/libexec/emryk/update-nudge.sh"
touch "$fixture_root/usr/libexec/emryk/arbitrary"

if output=$(PAYLOAD_ROOT=$fixture_root RPM_BIN=$mock_rpm "$guard" 2>&1); then
    echo >&2 "payload guard accepted an arbitrary Emryk helper"
    exit 1
fi

grep -Fq "$fixture_root/usr/libexec/emryk/arbitrary" <<<"$output"
if grep -Fq "$fixture_root/usr/libexec/emryk/install-flatpaks.sh" <<<"$output"; then
    echo >&2 "exactly allowlisted helper was queried as unowned"
    exit 1
fi

echo "payload guard negative tests passed"
