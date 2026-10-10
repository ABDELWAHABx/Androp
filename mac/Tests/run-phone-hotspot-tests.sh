#!/usr/bin/env bash
set -euo pipefail
test_root=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
swiftc -swift-version 5 "$test_root/airsync-mac/Core/PhoneHotspotManager.swift" \
    "$test_root/airsync-mac/Core/PhoneHotspotTransport.swift" \
    "$test_root/Tests/PhoneHotspotManagerRegression.swift" -o "$test_dir/hotspot-tests"
"$test_dir/hotspot-tests"
swiftc -swift-version 5 "$test_root/airsync-mac/Core/HotspotWiFiPolicy.swift" \
    "$test_root/Tests/HotspotWiFiPolicyRegression.swift" -o "$test_dir/hotspot-wifi-tests"
"$test_dir/hotspot-wifi-tests"
