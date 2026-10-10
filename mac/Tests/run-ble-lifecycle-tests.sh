#!/usr/bin/env bash
set -euo pipefail
if [[ "$(uname -s)" != Darwin ]] || ! command -v swiftc >/dev/null 2>&1; then
    echo "BLE lifecycle tests require macOS with Swift and CoreBluetooth."
    exit 77
fi
test_root=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
cp "$test_root/Tests/BLELifecycleRegression.swift" "$test_dir/main.swift"
swiftc -swift-version 5 -D BLE_LIFECYCLE_TESTS \
    "$test_root/airsync-mac/Core/BLE/BLECentralManager.swift" \
    "$test_root/airsync-mac/Core/BLE/BLEConstants.swift" \
    "$test_root/airsync-mac/Core/BLE/BLEChunkUtil.swift" \
    "$test_root/airsync-mac/Model/DeviceStatus.swift" \
    "$test_root/Tests/BLELifecycleRegressionStubs.swift" \
    "$test_dir/main.swift" -o "$test_dir/ble-lifecycle-tests"
"$test_dir/ble-lifecycle-tests"
