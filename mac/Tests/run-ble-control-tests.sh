#!/usr/bin/env bash
set -euo pipefail
test_root=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
swiftc "$test_root/airsync-mac/Core/BLE/BLEControlPolicy.swift" \
    "$test_root/Tests/BLEControlPolicyRegression.swift" -o "$test_dir/ble-control-tests"
"$test_dir/ble-control-tests"
