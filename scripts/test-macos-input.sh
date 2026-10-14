#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/ai-usage-input.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
swiftc "$root/Sources/AIUsageHerdrKit/DashboardInput.swift" \
    "$root/scripts/test-macos-input.swift" -o "$test_dir/test-input"
"$test_dir/test-input"
