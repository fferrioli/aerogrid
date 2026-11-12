#!/bin/zsh
# Regenerate scripts/aerospace-grid.patch from vendor/AeroSpace/Sources against the
# AeroSpace revision pinned in UPSTREAM.md. Works in a temporary clone; never touches
# the checkout except for the patch file. Usage: zsh scripts/regenerate-backend-patch.sh
set -euo pipefail
root=${0:A:h:h}
pin=$(sed -n 's/^- AeroSpace: `\([0-9a-f]\{40\}\)`.*/\1/p' "$root/UPSTREAM.md")
[[ -n $pin ]] || { print -u2 "AeroSpace pin not found in UPSTREAM.md"; exit 1 }
work=$(mktemp -d "${TMPDIR:-/tmp}/aerogrid-upstream.XXXXXX")
trap 'rm -rf "$work"' EXIT
git clone -q https://github.com/nikitabobko/AeroSpace.git "$work/upstream"
git -C "$work/upstream" checkout -q "$pin"
rsync -a --delete "$root/vendor/AeroSpace/Sources/" "$work/upstream/Sources/"
git -C "$work/upstream" add -A Sources
git -C "$work/upstream" diff --cached --binary --abbrev=7 --no-ext-diff -- Sources > "$root/scripts/aerospace-grid.patch"
print "regenerated scripts/aerospace-grid.patch against $pin"
