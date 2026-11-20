#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/module-cache .build/native-check
sources=(Sources/MarginCore/*.swift)
for source in Sources/MarginNotes/*.swift; do
  if [[ "$source" != */MarginNotesApp.swift ]]; then sources+=("$source"); fi
done
xcrun swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macosx14.0" \
  -module-cache-path "$PWD/.build/module-cache" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Scripts/NativeChecks-Info.plist \
  "${sources[@]}" Scripts/NativeChecks.swift Scripts/AgentNativeChecks.swift Scripts/SidebarNativeChecks.swift Scripts/BlockInteractionNativeChecks.swift Scripts/CanvasHitNativeChecks.swift Scripts/CanvasPointerNativeChecks.swift Scripts/ShowcaseNativeChecks.swift Scripts/AttachmentInteractionNativeChecks.swift Scripts/PagingHitNativeChecks.swift Scripts/AttachmentPagingNativeChecks.swift Scripts/ImageAttachmentNativeChecks.swift Scripts/FolderOverviewNativeChecks.swift Scripts/FolderOverviewUINativeChecks.swift -o .build/native-check/NativeChecks
.build/native-check/NativeChecks "$@"
