#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

failed=0
mapfile -t markdown_files < <(
    find . -type f -name '*.md' \
        -not -path './.git/*' \
        -not -path './docs/archive/*' \
        -print | LC_ALL=C sort
)

for markdown_file in "${markdown_files[@]}"; do
    while IFS= read -r link; do
        target=${link#*](}
        target=${target%)}
        target=${target#<}
        target=${target%>}
        case "$target" in
            ''|'#'*|http://*|https://*|mailto:*|oci://*) continue ;;
        esac
        target=${target%%#*}
        [[ -n $target ]] || continue
        resolved=$(dirname "$markdown_file")/$target
        if [[ ! -e $resolved ]]; then
            printf >&2 '%s: missing relative link target: %s\n' \
                "$markdown_file" "$target"
            failed=1
        fi
    done < <(grep -Eo '\[[^]]+\]\([^)]+\)' "$markdown_file" || true)
done

(( failed == 0 ))
echo 'repository-relative Markdown links passed'
