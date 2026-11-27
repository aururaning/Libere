#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/module-cache .build/native-check
optimization=(-Onone)
if [[ "${1:-}" == '--optimized' ]]; then
  optimization=(-O -whole-module-optimization)
  shift
fi
sources=(Sources/MarginCore/*.swift)
for source in Sources/MarginNotes/*.swift; do
  if [[ "$source" != */MarginNotesApp.swift ]]; then sources+=("$source"); fi
done
xcrun swiftc -g "${optimization[@]}" -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macosx14.0" \
  -module-cache-path "$PWD/.build/module-cache" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Scripts/NativeChecks-Info.plist \
  "${sources[@]}" Scripts/*NativeChecks.swift -o .build/native-check/NativeChecks
.build/native-check/NativeChecks "$@"
