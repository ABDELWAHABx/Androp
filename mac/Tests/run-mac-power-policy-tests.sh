#!/usr/bin/env bash
set -euo pipefail
if ! command -v swiftc >/dev/null 2>&1; then
    echo "Swift compiler unavailable; policy tests require a Swift host."
    exit 77
fi
test_root=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
cp "$test_root/Tests/MacKeepAwakePolicyTests.swift" "$test_dir/main.swift"
swiftc "$test_root/airsync-mac/Core/Util/MacInfo/MacKeepAwakePolicy.swift" "$test_dir/main.swift" -o "$test_dir/power-policy-tests"
"$test_dir/power-policy-tests"
