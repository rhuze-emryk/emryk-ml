#!/bin/bash
set -euo pipefail

shift # -qf
for path in "$@"; do
    printf 'file %s is not owned by any package\n' "$path"
done
exit 1
