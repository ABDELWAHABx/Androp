#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
androp_tests_dir="$(mktemp -d)"
trap 'rm -rf "$androp_tests_dir"' EXIT
swiftc airsync-mac/Core/Remote/Scrcpy/ScrcpyPacketParser.swift \
  Tests/ScrcpyPacketParserRegression.swift -o "$androp_tests_dir/scrcpy-tests"
"$androp_tests_dir/scrcpy-tests"
