#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
androp_tests_dir="$(mktemp -d)"
trap 'rm -rf "$androp_tests_dir"' EXIT
swiftc airsync-mac/Core/Util/Remote/MacRemoteInputPolicy.swift \
  Tests/MacRemoteInputRegression.swift -o "$androp_tests_dir/remote-tests"
"$androp_tests_dir/remote-tests"
