#!/bin/bash
set -euo pipefail
source_dir="$(cd "$(dirname "$0")/.." && pwd)"
base_app="${TABLELOG_BASE_APP:-$HOME/Applications/테이블로그.app}"
stage_root="$(mktemp -d "${TMPDIR:-/tmp}/TableLogSpeakerPreview.XXXXXX")"
stage_app="$stage_root/TableLog Speaker Preview.app"
cp -cR "$base_app" "$stage_app"
python3 - "$source_dir" "$stage_root" "$stage_app" <<'PY'
from pathlib import Path
import plistlib, sys
source, stage, app = map(Path, sys.argv[1:])
files = sorted(str(p) for p in (source/'Sources').glob('*.swift') if p.name not in ['TableLogApp.swift', 'AppModel.swift', 'VoiceIdentity.swift'])
for name, fixture in [('AppModel.swift', 'EditingFixture.swift.inc'), ('VoiceIdentity.swift', 'VoiceIdentityFixture.swift.inc')]:
    path = stage/name
    path.write_text((source/'Sources'/name).read_text()+'\n'+(source/'Verification'/fixture).read_text())
    files.append(str(path))
files.append(str(source/'Verification/SpeakerPreviewApp.swift'))
(stage/'sources.txt').write_text('\n'.join(files)+'\n')
info = plistlib.loads((source/'Resources/Info.plist').read_bytes())
info.update(CFBundleIdentifier='local.TableLog.SpeakerPreview.'+stage.name.split('.')[-1],
            CFBundleName='TableLog Speaker Preview', CFBundleDisplayName='TableLog Speaker Preview')
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY
xcrun swiftc -module-cache-path "${TABLELOG_MODULE_CACHE:-$source_dir/.build-cache}" -O -whole-module-optimization -swift-version 5 -D TABLELOG_VERIFICATION \
  -target arm64-apple-macosx26.0 -module-name TableLogSpeakerPreview -I "$source_dir/Native" -I "$source_dir/Native/Sherpa" \
  @"$stage_root/sources.txt" "$source_dir/Native/libHwajaNative.a" -L "$stage_app/Contents/Frameworks" \
  -lnemo_speech_asr -lsherpa-onnx-c-api -lc++ -framework PDFKit -framework Vision -framework Contacts \
  -framework SwiftUI -framework AppKit -framework AVFoundation -framework Security -framework CoreAudio \
  -framework AudioToolbox -framework UniformTypeIdentifiers \
  -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' -o "$stage_app/Contents/MacOS/TableLog"
codesign --force --sign - --entitlements "$source_dir/Resources/Entitlements.plist" "$stage_app"
codesign --verify --deep --strict "$stage_app"
printf '%s\n' "$stage_app"
