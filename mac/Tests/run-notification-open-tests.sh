#!/usr/bin/env bash
set -euo pipefail
test_root=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
swiftc "$test_root/airsync-mac/Core/Util/NotificationOpenPolicy.swift" \
    "$test_root/Tests/NotificationOpenPolicyRegression.swift" -o "$test_dir/notification-open-tests"
"$test_dir/notification-open-tests"
