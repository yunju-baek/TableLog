#!/bin/bash
set -euo pipefail
source_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$source_dir"
mkdir -p .verification
python3 - <<'PY'
from pathlib import Path
files=sorted(str(p) for p in Path('Sources').glob('*.swift') if p.name != 'TableLogApp.swift')
Path('.verification/minutes-sources.txt').write_text('\n'.join(files+['Verification/MinutesChecks.swift'])+'\n')
PY
frameworks="${TABLELOG_BASE_APP:-$HOME/Applications/테이블로그.app}/Contents/Frameworks"
xcrun swiftc -module-cache-path .build-cache -swift-version 5 -target arm64-apple-macosx26.0 \
  -module-name TableLogMinutesChecks -I Native -I Native/Sherpa @.verification/minutes-sources.txt \
  Native/libHwajaNative.a -L "$frameworks" -lnemo_speech_asr -lsherpa-onnx-c-api -lc++ \
  -framework PDFKit -framework Vision -framework Contacts -framework SwiftUI -framework AppKit \
  -framework AVFoundation -framework Security -framework CoreAudio -framework AudioToolbox -framework UniformTypeIdentifiers \
  -Xlinker -rpath -Xlinker "$frameworks" -o .verification/MinutesChecks
.verification/MinutesChecks "$@"
