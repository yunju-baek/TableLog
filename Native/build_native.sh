#!/bin/bash
set -euo pipefail
if [ "$#" != 2 ]; then
    printf 'Usage: %s /path/to/NeMo-Speech.cpp /path/to/build/native\n' "$0" >&2
    exit 2
fi
source_dir="$(cd "$1" && pwd)"
native_dir="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$2"
build_dir="$(cd "$2" && pwd)"
includes=("$source_dir/src/asr" "$source_dir/src/common" "$source_dir/src/runtime/ggml"
          "$source_dir/src/asr/features" "$source_dir/src/asr/encoder"
          "$source_dir/src/asr/decoders" "$source_dir/src/asr/diar"
          "$source_dir/src/asr/vad" "$source_dir/llama.cpp/ggml/include" "$native_dir")
flags=()
for path in "${includes[@]}"; do flags+=( -I "$path" ); done
xcrun clang++ -std=c++17 -O2 -fPIC -mmacosx-version-min=26.0 "${flags[@]}" \
    -c "$native_dir/HwajaEngine.cpp" -o "$build_dir/HwajaEngine.o"
xcrun libtool -static -o "$build_dir/libHwajaNative.a" "$build_dir/HwajaEngine.o"
printf 'Built native adapter: %s\n' "$build_dir/libHwajaNative.a"
