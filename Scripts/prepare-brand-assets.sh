#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Package the supplied artwork at Apple's required icon sizes. The source PNG is unchanged.
source_png='Sources/MarginNotes/Resources/BrandLogo.png'
catalog='Sources/MarginNotes/Resources/Assets.xcassets'
icons="$catalog/AppIcon.appiconset"
test -f "$source_png"
mkdir -p "$icons"
for size in 16 32 128 256 512; do
  for scale in 1 2; do
    suffix=''
    if [[ "$scale" == 2 ]]; then suffix='@2x'; fi
    pixels=$((size * scale))
    sips -z "$pixels" "$pixels" "$source_png" --out "$icons/icon_${size}x${size}${suffix}.png" >/dev/null
  done
done
for size in 20 29 40 76; do
  for scale in 1 2; do
    pixels=$((size * scale))
    sips -z "$pixels" "$pixels" "$source_png" --out "$icons/ipad_${size}_${scale}x.png" >/dev/null
  done
done
sips -z 167 167 "$source_png" --out "$icons/ipad_83.5_2x.png" >/dev/null
sips -z 1024 1024 "$source_png" --out "$icons/store_1024.png" >/dev/null
python3 - <<'PY'
from pathlib import Path
import json
catalog=Path('Sources/MarginNotes/Resources/Assets.xcassets')
info={'author':'xcode','version':1}
(catalog/'Contents.json').write_text(json.dumps({'info':info},indent=2)+'\n')
images=[]
for size in [16,32,128,256,512]:
    for scale in [1,2]:
        suffix='@2x' if scale==2 else ''
        images.append({'idiom':'mac','size':f'{size}x{size}','scale':f'{scale}x','filename':f'icon_{size}x{size}{suffix}.png'})
for size in [20,29,40,76,83.5]:
    for scale in ([2] if size==83.5 else [1,2]):
        images.append({'idiom':'ipad','size':f'{size}x{size}','scale':f'{scale}x','filename':f'ipad_{size}_{scale}x.png'})
images.append({'idiom':'ios-marketing','size':'1024x1024','scale':'1x','filename':'store_1024.png'})
(catalog/'AppIcon.appiconset/Contents.json').write_text(json.dumps({'images':images,'info':info},indent=2)+'\n')
print(f'Prepared {len(images)} Mac/iPad icon variants from the unchanged logo.')
PY
