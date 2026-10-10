#!/usr/bin/env bash
set -euo pipefail
test_root=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
bash "$test_root/Tests/run-mac-power-policy-tests.sh"
bash "$test_root/Tests/run-ble-lifecycle-tests.sh"
bash "$test_root/Tests/run-scrcpy-packet-tests.sh"
bash "$test_root/Tests/run-remote-input-tests.sh"
bash "$test_root/Tests/run-nearby-metadata-tests.sh"
bash "$test_root/Tests/run-phone-battery-policy-tests.sh"
swiftc "$test_root/airsync-mac/Model/NowPlayingInfo.swift" \
    "$test_root/Tests/NowPlayingInfoRegression.swift" -o "$test_dir/media-tests"
"$test_dir/media-tests"
