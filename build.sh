#!/bin/bash
set -euo pipefail
source_dir="$(cd "$(dirname "$0")" && pwd)"
base_app="${1:-$HOME/Applications/테이블로그.app}"
stage_root="$(mktemp -d "${TMPDIR:-/tmp}/TableLogBuild.XXXXXX")"
stage_app="$stage_root/테이블로그.app"
cp -cR "$base_app" "$stage_app"
runtime_dir="${TABLELOG_RUNTIME_DIR:-$source_dir/.runtime/v0.2.0}"
native_library="$source_dir/Native/libHwajaNative.a"
if [[ -d "$runtime_dir/Frameworks" ]]; then
  cp "$runtime_dir/Frameworks/"*.dylib "$stage_app/Contents/Frameworks/"
  cp -R "$runtime_dir/Notices/." "$stage_app/Contents/Resources/Notices/"
  native_library="$runtime_dir/libHwajaNative.a"
fi
# The bridge uses the pinned C++ ABI. Check the pair before linking.
python3 - "$stage_app/Contents/Resources/Notices/Engine-Provenance.json" "$native_library" "$stage_app/Contents/Frameworks" <<'PY'
import hashlib,json,pathlib,sys
manifest=json.loads(pathlib.Path(sys.argv[1]).read_text())
assert manifest['revision']=='6a3ca369370782acee0dd155e34394ba60b920c4', 'Build the v0.2.0 runtime first'
for name,digest in manifest['sha256'].items():
    p=pathlib.Path(sys.argv[2]) if name=='libHwajaNative.a' else pathlib.Path(sys.argv[3])/name
    assert hashlib.sha256(p.read_bytes()).hexdigest()==digest, f'Runtime/bridge mismatch: {name}'
PY
xcrun swiftc -module-cache-path "$source_dir/.build-cache" -O -whole-module-optimization -swift-version 5 -target arm64-apple-macosx26.0 \
  -module-name TableLog -I "$source_dir/Native" -I "$source_dir/Native/Sherpa" \
  "$source_dir"/Sources/*.swift "$native_library" \
  -L "$stage_app/Contents/Frameworks" -lnemo_speech_asr -lsherpa-onnx-c-api -lc++ \
  -framework PDFKit -framework Vision -framework Contacts -framework SwiftUI -framework AppKit -framework AVFoundation -framework Security \
  -framework CoreAudio -framework AudioToolbox -framework UniformTypeIdentifiers \
  -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' -o "$stage_app/Contents/MacOS/TableLog"
rm -f "$stage_app/Contents/MacOS/HwajaNote"
cp "$source_dir/Resources/Info.plist" "$stage_app/Contents/Info.plist"
# Model weights live outside the replaceable app bundle.
if [[ -d "$stage_app/Contents/Resources/Models" || -L "$stage_app/Contents/Resources/Models" ]]; then
  rm -rf "$stage_app/Contents/Resources/Models"
fi
# Retired local language-model resources stay out of rebuilt applications.
rm -rf "$stage_app/Contents/Resources/LocalCorrector"
rm -f "$stage_app/Contents/Resources/Notices/LocalCorrector-Provenance.txt" "$stage_app/Contents/Resources/Notices/Qwen3.5-LICENSE.txt"
codesign --force --sign - --entitlements "$source_dir/Resources/Entitlements.plist" "$stage_app"
codesign --verify --deep --strict "$stage_app"
printf '%s\n' "$stage_app"
