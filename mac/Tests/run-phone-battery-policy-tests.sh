#!/usr/bin/env bash
set -euo pipefail
if ! command -v swiftc >/dev/null 2>&1; then
    echo "Swift compiler unavailable; battery policy tests require a Swift host."
    exit 77
fi
test_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
swiftc "$test_root/airsync-mac/Core/PhoneBatteryAlertPolicy.swift" \
    "$test_root/Tests/PhoneBatteryAlertPolicyRegression.swift" -o "$test_dir/battery-policy-tests"
"$test_dir/battery-policy-tests"
