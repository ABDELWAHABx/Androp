#!/usr/bin/env bash
set -euo pipefail
test_root=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
cp "$test_root/Tests/BLEFileLaneProtocolRegression.swift" "$test_dir/main.swift"
swiftc -swift-version 5 "$test_root/airsync-mac/Core/BLE/BLEFileLaneProtocol.swift" \
    "$test_dir/main.swift" -o "$test_dir/ble-file-lane-tests"
"$test_dir/ble-file-lane-tests"
