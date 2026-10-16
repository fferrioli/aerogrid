#!/bin/zsh
set -eu
cd "${0:A:h}"

finish() { echo; read -r '?Press Return to close this installer.' || true }
trap finish EXIT
if [[ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null || true)" != 1 ]]; then
    echo 'This package requires an Apple Silicon Mac (M1 or later).'
    exit 1
fi
if (( ${$(/usr/bin/sw_vers -productVersion)%%.*} < 14 )); then
    echo 'This package requires macOS 14 or later.'
    exit 1
fi
if ! command -v python3 >/dev/null || ! python3 -c 'import sys; sys.exit(sys.version_info < (3, 9))'; then
    echo 'Python 3.9 or later is required to run this installer. No Swift build is needed.'
    exit 1
fi
echo 'Installing AeroGrid for this user. Existing configuration will be backed up.'
python3 scripts/install.py
echo 'Enable AeroGrid and AeroGrid Backend in System Settings > Privacy & Security > Accessibility.'
echo 'Then click Recover in AeroGrid. See README.txt for gesture setup.'
open "$HOME/Applications/AeroGrid.app"
