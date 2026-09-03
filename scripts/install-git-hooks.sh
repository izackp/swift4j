#!/usr/bin/env bash
set -euo pipefail

root=$(git rev-parse --show-toplevel)
src="$root/scripts/git-hooks"
dst="$(git rev-parse --git-path hooks)"

for hook in "$src"/*; do
    name=$(basename "$hook")
    ln -sf "../../scripts/git-hooks/$name" "$dst/$name"
    chmod +x "$hook"
    echo "installed $name"
done
