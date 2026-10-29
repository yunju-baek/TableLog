#!/usr/bin/env python3
"""Download a pinned Qwen source and convert it once; not run by API requests."""
from pathlib import Path


def main():
    destination = Path.home() / "Library/Application Support/TableLogServer/models/qwen3.5-4b-4bit"
    if destination.exists():
        raise SystemExit("Model directory already exists; inspect or move it before rebuilding.")
    from huggingface_hub import snapshot_download
    from mlx_lm import convert
    source = snapshot_download(
        "Qwen/Qwen3.5-4B",
        revision="851bf6e806efd8d0a36b00ddf55e13ccb7b8cd0a",
        allow_patterns=["*.json", "*.safetensors", "*.jinja", "*.txt", "LICENSE*", "README.md"],
    )
    destination.parent.mkdir(parents=True, exist_ok=True)
    convert(hf_path=source, mlx_path=str(destination), quantize=True, q_bits=4, trust_remote_code=False)
    print(f"Text model ready: {destination}")


if __name__ == "__main__":
    main()
