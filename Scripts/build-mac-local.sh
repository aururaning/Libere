#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$(uname -s)" != Darwin ]; then
  echo 'Run this build on macOS.' >&2
  exit 2
fi
if ! xcodebuild -version >/dev/null 2>&1; then
  sibling_xcode="$(dirname "$PWD")/Xcode.app/Contents/Developer"
  if [[ -z "${DEVELOPER_DIR:-}" && -x "$sibling_xcode/usr/bin/xcodebuild" ]]; then
    export DEVELOPER_DIR="$sibling_xcode"
  fi
fi
# Use Xcode's complete asset pipeline. An already successful check.sh Mac build
# may be reused within this same source revision without invoking icon writers again.
if [[ "${1:-}" != '--reuse-sdk-build' ]]; then
  build_scratch=$(mktemp -d "${TMPDIR:-/tmp}/libere-mac-build.XXXXXX")
  trap 'rm -rf "$build_scratch"' EXIT
  xcodebuild -project MarginNotes.xcodeproj -scheme MarginNotes -configuration Debug \
    -destination 'generic/platform=macOS' -derivedDataPath "$build_scratch" \
    SYMROOT="$PWD/.build/XcodeProducts" CODE_SIGNING_ALLOWED=NO build
fi
python3 - <<'CHECK'
from pathlib import Path
import plistlib,re
root=Path('.')
bundle=root/'.build/XcodeProducts/Debug/Libere.app/Contents'
info=plistlib.loads((bundle/'Info.plist').read_bytes())
config=(root/'Config/Base.xcconfig').read_text()
def setting(name): return re.search(r'^'+name+r'\s*=\s*(.+)$',config,re.M).group(1).strip()
assert info['CFBundleShortVersionString']==setting('MARKETING_VERSION')
assert info['CFBundleVersion']==setting('CURRENT_PROJECT_VERSION')
assert info['CFBundleIdentifier']==setting('PRODUCT_BUNDLE_IDENTIFIER')
assert info['CFBundleName']==info['CFBundleDisplayName']==info['CFBundleExecutable']=='Libere'
assert info['CFBundleIconName']=='AppIcon'
resources=bundle/'Resources'
assert (resources/'BrandLogo.png').read_bytes()==(root/'Sources/MarginNotes/Resources/BrandLogo.png').read_bytes()
assert (resources/'notebook_kernel.py').read_bytes()==(root/'Sources/MarginNotes/Resources/notebook_kernel.py').read_bytes()
for name in ('libere_agent.py','agent_rules.md','agent_tools.json','agent_openapi.json','Showcase.json'):
    assert (resources/name).read_bytes()==(root/'Sources/MarginNotes/Resources'/name).read_bytes()
assert (resources/'AppIcon.icns').is_file() and (resources/'Assets.car').is_file()
latest_icon=max(p.stat().st_mtime for p in (root/'Sources/MarginNotes/Resources/Assets.xcassets').rglob('*') if p.is_file())
assert (resources/'Assets.car').stat().st_mtime>=latest_icon, 'Rebuild the changed asset catalog first.'
CHECK
mkdir -p .build/module-cache
# Keep the existing standalone app's bookmark behavior and opt-in window helper.
# The installer runs this standalone executable; optimize it even though the SDK
# build above is also used to validate development resources.
xcrun swiftc -O -whole-module-optimization -D MARGIN_LOCAL_BUILD -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macosx14.0" \
  -module-cache-path "$PWD/.build/module-cache" \
  Sources/MarginCore/*.swift Sources/MarginNotes/*.swift Scripts/MacWindowCheck.swift \
  -o .build/XcodeProducts/Debug/Libere.app/Contents/MacOS/Libere
python3 - <<'BUILD'
from pathlib import Path
import plistlib,subprocess,shutil
bundle=Path('.build/XcodeProducts/Debug/Libere.app/Contents')
for notice in ('LICENSE', 'NOTICE', 'THIRD_PARTY_NOTICES.md'):
    shutil.copyfile(notice, bundle/'Resources'/notice)
# The standalone executable above contains the app code directly, so Xcode's
# generated preview/debug loader libraries are unused and must not ship unsigned.
for name in ('__preview.dylib','Libere.debug.dylib'):
    (bundle/'MacOS'/name).unlink(missing_ok=True)
p=bundle/'Info.plist'
info=plistlib.loads(p.read_bytes())
info.update(NSPrincipalClass='NSApplication',MarginCloudEnabled='NO',MarginCloudContainer='')
p.write_bytes(plistlib.dumps(info,sort_keys=False))
# Only clear signing-incompatible Finder metadata from this generated product.
app=bundle.parent
for path in [app,*app.rglob('*')]:
    attrs=subprocess.run(['xattr',str(path)],capture_output=True,text=True,check=True).stdout.splitlines()
    for attr in ('com.apple.FinderInfo','com.apple.ResourceFork'):
        if attr in attrs: subprocess.run(['xattr','-d',attr,str(path)],check=True)
BUILD
codesign --force --sign - .build/XcodeProducts/Debug/Libere.app
codesign --verify --verbose=2 .build/XcodeProducts/Debug/Libere.app
printf '%s\n' "$PWD/.build/XcodeProducts/Debug/Libere.app"
