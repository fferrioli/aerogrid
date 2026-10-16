#!/bin/zsh
set -eu
cd "${0:A:h}/.."
swift build -c release
cd vendor/AeroSpace
swift build -c release --product AeroSpaceApp
swift build -c release --product aerospace
