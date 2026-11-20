#!/usr/bin/env bash
# Build from this checkout, then package the newly generated app.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$(uname -s)" != Darwin ]; then
  echo 'Run this build on macOS.' >&2
  exit 2
fi
# --app could silently replace the fresh build with an older copy.
for arg in "$@"; do
  case "$arg" in
    --app|--app=*)
      echo 'Use package-mac.py directly to package an explicitly selected app.' >&2
      exit 2
      ;;
    -h|--help)
      echo 'Usage: bash Scripts/build-mac-package.sh [--format pkg|dmg] [--output-dir PATH]'
      exit 0
      ;;
  esac
done
bash Scripts/build-mac-local.sh
python3 Scripts/package-mac.py --app "$PWD/.build/XcodeProducts/Debug/Libere.app" "$@"
