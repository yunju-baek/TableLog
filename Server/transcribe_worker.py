#!/usr/bin/env python3
"""One request per process: Korean Whisper STT, no persistent model or network."""
import argparse
import json
import os
import wave
from pathlib import Path

os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    import numpy as np
    import mlx.core as mx
    from mlx_audio.stt.utils import load_model
    from transformers import WhisperProcessor
    cache = Path.home() / ".cache/huggingface/hub"
    checkpoint = cache / "models--mlx-community--whisper-large-v3-turbo/snapshots/a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb"
    processor = cache / "models--openai--whisper-large-v3-turbo/snapshots/41f01f3fe87f28c78e2fbf8b568835947dd65ed9"
    mx.set_memory_limit(16 * 1024**3)
    mx.set_cache_limit(1024**3)
    model = load_model(checkpoint)
    model._processor = WhisperProcessor.from_pretrained(processor, local_files_only=True)
    model.set_alignment_heads(json.loads((processor / "generation_config.json").read_text())["alignment_heads"])
    with wave.open(str(args.input), "rb") as audio:
        waveform = np.frombuffer(audio.readframes(audio.getnframes()), dtype="<i2").astype(np.float32) / 32768
    result = model.generate(waveform, language="ko", word_timestamps=False, temperature=0.0,
                            condition_on_previous_text=False, verbose=False)
    payload = {"text": result.text, "language": "ko", "segments": [
        {"start": s["start"], "end": s["end"], "text": s["text"]} for s in result.segments]}
    args.output.write_text(json.dumps(payload, ensure_ascii=False))


if __name__ == "__main__":
    main()
