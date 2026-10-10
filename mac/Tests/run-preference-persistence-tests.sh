#!/usr/bin/env bash
set -euo pipefail
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
cat > "$test_dir/main.swift" <<'SWIFT'
import Foundation
let domain = "app.androp.preference-test." + UUID().uuidString
let defaults = UserDefaults(suiteName: domain)!
defer { defaults.removePersistentDomain(forName: domain) }
precondition(!defaults.bool(forKey: "quickShareEnabled"), "Launch isolation must disable receiving initially")
defaults.set(true, forKey: "quickShareEnabled")
precondition(!defaults.bool(forKey: "quickShareEnabled"), "Launch arguments retain search-list precedence")
precondition(defaults.persistentDomain(forName: domain)?["quickShareEnabled"] as? Bool == true,
             "Persistent domain exposes Settings write despite launch override")
defaults.set(false, forKey: "quickShareEnabled")
precondition(defaults.persistentDomain(forName: domain)?["quickShareEnabled"] as? Bool == false,
             "Persistent domain exposes subsequent Settings change")
print("Preference persistence: 4 checks passed")
SWIFT
swiftc "$test_dir/main.swift" -o "$test_dir/preference-tests"
"$test_dir/preference-tests" -quickShareEnabled NO
