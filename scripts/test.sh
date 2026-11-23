#!/usr/bin/env bash
# Runs the swift-testing suite. On Command Line Tools-only machines the TestingMacros plugin
# lives in a subfolder the toolchain doesn't search by default, so add it when present.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXTRA=()
PLUGIN_DIR="/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
if [[ -d "$PLUGIN_DIR" ]]; then
  EXTRA=(-Xswiftc -plugin-path -Xswiftc "$PLUGIN_DIR")
fi
cd "$ROOT"
# ${EXTRA[@]+...}: an empty array is "unbound" under set -u in macOS bash 3.2.
swift test --scratch-path "${ROOT}/.build-test" ${EXTRA[@]+"${EXTRA[@]}"} "$@"
