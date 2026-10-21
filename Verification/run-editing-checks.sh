#!/bin/bash
set -euo pipefail
source_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$source_dir"
mkdir -p .verification
python3 - <<'PY'
from pathlib import Path
Path('.verification/AppModel.swift').write_text(Path('Sources/AppModel.swift').read_text()+'\n'+Path('Verification/EditingFixture.swift.inc').read_text())
files=sorted(str(p) for p in Path('Sources').glob('*.swift') if p.name not in ['AppModel.swift','TableLogApp.swift'])
files+=['.verification/AppModel.swift','Verification/EditingChecks.swift']
Path('.verification/sources.txt').write_text('\n'.join(files)+'\n')
PY
frameworks="${TABLELOG_BASE_APP:-$HOME/Applications/테이블로그.app}/Contents/Frameworks"
xcrun swiftc -module-cache-path .build-cache -swift-version 5 -D TABLELOG_VERIFICATION \
  -target arm64-apple-macosx26.0 -module-name TableLogEditingChecks -I Native -I Native/Sherpa \
  @.verification/sources.txt Native/libHwajaNative.a -L "$frameworks" \
  -lnemo_speech_asr -lsherpa-onnx-c-api -lc++ -framework PDFKit -framework Vision \
  -framework Contacts -framework SwiftUI -framework AppKit -framework AVFoundation \
  -framework Security -framework CoreAudio -framework AudioToolbox -framework UniformTypeIdentifiers \
  -Xlinker -rpath -Xlinker "$frameworks" -o .verification/EditingChecks
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/TableLogEditingChecks.XXXXXX")"
.verification/EditingChecks "$fixture_root" "$@"
