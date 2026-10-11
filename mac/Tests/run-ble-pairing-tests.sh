#!/usr/bin/env bash
set -euo pipefail
test_root=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
swiftc -swift-version 5 \
    "$test_root/airsync-mac/Core/BLE/BLEPairingProtocol.swift" \
    "$test_root/airsync-mac/Core/BLE/BLEChunkUtil.swift" \
    "$test_root/airsync-mac/Core/BLE/BLEConstants.swift" \
    "$test_root/airsync-mac/Core/BLE/BLEAdvertisementProof.swift" \
    "$test_root/Tests/BLEPairingProtocolRegression.swift" -o "$test_dir/ble-pairing-tests"
"$test_dir/ble-pairing-tests"
