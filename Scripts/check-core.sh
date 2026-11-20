#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/module-cache .build/core-check
xcrun swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macosx14.0" \
  -module-cache-path "$PWD/.build/module-cache" \
  Sources/MarginCore/*.swift Scripts/CoreChecks.swift -o .build/core-check/CoreChecks
.build/core-check/CoreChecks
