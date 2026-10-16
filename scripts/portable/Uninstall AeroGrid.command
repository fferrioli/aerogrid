#!/bin/zsh
set -eu
cd "${0:A:h}"
finish() { echo; read -r '?Press Return to close this uninstaller.' || true }
trap finish EXIT
echo 'Quit AeroGrid using its menu-bar menu before continuing.'
python3 scripts/uninstall.py
