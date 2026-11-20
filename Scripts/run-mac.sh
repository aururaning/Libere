#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash Scripts/build-mac-local.sh
app="$PWD/.build/XcodeProducts/Debug/Libere.app"
if (( $# )); then
  open -n "$app" --args "$@"
else
  open "$app"
fi
