#!/bin/bash
set -euo pipefail
source_dir="$(cd "$(dirname "$0")/.." && pwd)"
binary="$(mktemp "${TMPDIR:-/tmp}/TableLogProcessChecks.XXXXXX")"
trap 'rm -f "$binary"' EXIT
xcrun swiftc -module-cache-path "${TABLELOG_MODULE_CACHE:-$source_dir/.build-cache}" \
  -target arm64-apple-macosx26.0 "$source_dir/Sources/ManagedChildProcess.swift" \
  "$source_dir/Verification/ProcessExitChecks.swift" -o "$binary"
"$binary"
