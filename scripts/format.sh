#!/usr/bin/env bash
# Formats every Swift source in place with the toolchain's swift-format.
#
# The configuration lives in `.swift-format` at the repository root. swift-format ships
# inside Xcode, so this needs no Homebrew dependency: `xcrun` finds it in the selected
# toolchain.
#
# `scripts/check.sh` verifies that running this changes nothing; run it after editing.
set -euo pipefail

cd "$(dirname "$0")/.."
# Packages/*/.build is a build product; swift-format would happily walk into it.
xcrun swift-format format --parallel --in-place --recursive \
    Sources Tests Packages/TranscriberCore/Sources Packages/TranscriberCore/Tests \
    Packages/TranscriberCore/Package.swift
echo "formatted Sources, Tests and Packages"
