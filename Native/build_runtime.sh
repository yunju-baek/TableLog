#!/bin/bash
set -euo pipefail
if [[ $# != 2 ]]; then
  echo "Usage: $0 /path/to/NeMo-Speech.cpp /path/to/runtime-output" >&2
  exit 2
fi
source_dir="$(cd "$1" && pwd)"
native_dir="$(cd "$(dirname "$0")" && pwd)"
revision=6a3ca369370782acee0dd155e34394ba60b920c4
[[ "$(git -C "$source_dir" rev-parse HEAD)" == "$revision" ]] || { echo 'Expected NeMo-Speech.cpp v0.2.0' >&2; exit 1; }
mkdir -p "$2"
output_dir="$(cd "$2" && pwd)"
build_dir="${TABLELOG_NEMO_BUILD_DIR:-$source_dir/build-tablelog}"
if [[ ! -f "$source_dir/.deps/sentencepiece/lib/libsentencepiece.a" ]]; then
  bash "$source_dir/scripts/build_sentencepiece_static.sh"
fi
cmake -S "$source_dir" -B "$build_dir" -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 -DBUILD_SHARED_LIBS=ON \
  -DGGML_NATIVE=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
  -DNEMO_SPEECH_BUILD_TTS=OFF -DNEMO_SPEECH_BUILD_CLI=OFF \
  -DNEMO_SPEECH_BUILD_MIC_CAPTURE=OFF \
  -DNEMO_SPEECH_DEPENDENCY_PREFIX="$source_dir/.deps"
cmake --build "$build_dir" --target nemo_speech_asr -j 6
bash "$native_dir/build_native.sh" "$source_dir" "$output_dir"
mkdir -p "$output_dir/Frameworks" "$output_dir/Notices/SentencePiece"
for name in libnemo_speech_asr.dylib libggml.0.dylib libggml-base.0.dylib libggml-cpu.0.dylib libggml-blas.0.dylib libggml-metal.0.dylib; do
  cp -L "$build_dir/bin/$name" "$output_dir/Frameworks/$name"
  # Resolve every runtime dependency inside the application bundle.
  while IFS= read -r path; do
    if [[ "$path" != '@loader_path' ]]; then install_name_tool -delete_rpath "$path" "$output_dir/Frameworks/$name"; fi
  done < <(otool -l "$output_dir/Frameworks/$name" | awk '/cmd LC_RPATH/{getline;getline;print $2}')
  if ! otool -l "$output_dir/Frameworks/$name" | grep -q 'path @loader_path '; then
    install_name_tool -add_rpath '@loader_path' "$output_dir/Frameworks/$name"
  fi
  codesign --force --sign - "$output_dir/Frameworks/$name"
done
cp "$source_dir/LICENSE" "$output_dir/Notices/NeMo-Speech-LICENSE.txt"
cp "$source_dir/NOTICE" "$output_dir/Notices/NeMo-Speech-NOTICE.txt"
cp "$source_dir/THIRD_PARTY_NOTICES.md" "$output_dir/Notices/THIRD_PARTY_NOTICES.md"
cp "$source_dir/llama.cpp/LICENSE" "$output_dir/Notices/llama.cpp-LICENSE.txt"
cp "$source_dir/llama.cpp/LICENSE" "$output_dir/Notices/ggml-LICENSE.txt"
cp "$source_dir/.deps/sentencepiece/share/licenses/nemo-speech/third_party/sentencepiece/"* "$output_dir/Notices/SentencePiece/"
python3 - "$output_dir" "$revision" <<'PY'
import hashlib,json,pathlib,sys
root=pathlib.Path(sys.argv[1])
files=list((root/'Frameworks').glob('*.dylib'))+[root/'libHwajaNative.a']
manifest={'engine':'NVIDIA/NeMo-Speech.cpp','version':'0.2.0','revision':sys.argv[2],
          'llama_revision':'bd4f514db14d87fded667787a7a963bfbaa98e89','backend':'Metal',
          'endpointing':True,'normalization':'model-native punctuation; external ITN disabled',
          'sha256':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in files}}
(root/'Notices/Engine-Provenance.json').write_text(json.dumps(manifest,indent=2)+'\n')
PY
printf 'Runtime ready: %s\n' "$output_dir"
