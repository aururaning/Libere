#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 Scripts/verify_project.py
python3 Scripts/test_agent_bridge.py

if ! xcodebuild -version >/dev/null 2>&1; then
  sibling_xcode="$(dirname "$PWD")/Xcode.app/Contents/Developer"
  if [[ -z "${DEVELOPER_DIR:-}" && -x "$sibling_xcode/usr/bin/xcodebuild" ]]; then
    export DEVELOPER_DIR="$sibling_xcode"
  fi
fi
xcodebuild -version
xcrun --sdk iphonesimulator --show-sdk-path >/dev/null
# Keep intermediate metadata on the Mac temporary volume and final products on the project volume.
scratch=$(mktemp -d "${TMPDIR:-/tmp}/MarginNotes-check.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
mkdir -p .build/validation
export CLANG_MODULE_CACHE_PATH="$scratch/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
swift_args=(test --scratch-path "$scratch/package" --cache-path "$scratch/cache"
            --config-path "$scratch/config" --security-path "$scratch/security")
log="$PWD/.build/validation/xctest.log"
if ! xcrun swift "${swift_args[@]}" >"$log" 2>&1; then
  if grep -q 'sandbox_apply: Operation not permitted' "$log"; then
    # The package has no dependencies or plugins. The calling process remains sandboxed.
    xcrun swift "${swift_args[@]}" --disable-sandbox >"$log" 2>&1 || { cat "$log"; exit 1; }
  else
    cat "$log"
    exit 1
  fi
fi
tail -n 9 "$log"
for platform in macosx iphonesimulator iphoneos; do
  case "$platform" in
    macosx) destination='generic/platform=macOS' ;;
    iphonesimulator) destination='generic/platform=iOS Simulator' ;;
    iphoneos) destination='generic/platform=iOS' ;;
  esac
  log="$PWD/.build/validation/$platform.log"
  xcodebuild -project MarginNotes.xcodeproj -scheme MarginNotes -configuration Debug \
    -destination "$destination" -derivedDataPath "$scratch/Xcode" \
    SYMROOT="$PWD/.build/XcodeProducts" CODE_SIGNING_ALLOWED=NO build >"$log" 2>&1 \
    || { tail -n 60 "$log"; exit 1; }
  echo "$platform: $(tail -n 2 "$log" | head -n 1)"
done
