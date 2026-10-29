#!/usr/bin/env python3
"""Text-only local inference. No tools, shell, browsing, or persistent model process."""
import argparse
import json
import os
from pathlib import Path

os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
MODEL_DIR = Path.home() / "Library/Application Support/TableLogServer/models/qwen3.5-4b-4bit"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    from mlx_lm import load, generate
    from mlx_lm.sample_utils import make_sampler
    import mlx.core as mx
    mx.set_memory_limit(12 * 1024**3)
    mx.set_cache_limit(512 * 1024**2)
    data = json.loads(args.input.read_text())
    model, tokenizer = load(str(MODEL_DIR), tokenizer_config={"trust_remote_code": False})
    prompt = tokenizer.apply_chat_template(data["messages"], tokenize=True, add_generation_prompt=True, enable_thinking=False)
    if len(prompt) > 24000:
        raise ValueError("Text context exceeds 24000 tokens")
    response = generate(model, tokenizer, prompt=prompt, max_tokens=min(data.get("max_tokens", 2048), 3072),
                        sampler=make_sampler(temp=0.1), verbose=False)
    if not response.strip():
        raise ValueError("Empty model response")
    args.output.write_text(json.dumps({"choices": [{"message": {"role": "assistant", "content": response.strip()}}]}, ensure_ascii=False))


if __name__ == "__main__":
    main()
