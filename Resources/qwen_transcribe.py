"""Run the installed MLX models and emit the timed transcription for TableLog."""

import json
import sys
from pathlib import Path

from mlx_qwen3_asr import transcribe
from mlx_qwen3_asr.forced_aligner import ForcedAlignTextProcessor


def timed_words(text, tokens, start, end):
    """Use the aligner's timing and keep the transcript's original punctuation."""
    clean = ForcedAlignTextProcessor.clean_token
    raw_words = text.split()
    if "".join(map(clean, raw_words)) != "".join(token["text"] for token in tokens):
        raise ValueError("Qwen alignment differs from the transcript")

    words = []
    index = 0
    remaining = len(tokens[0]["text"]) if tokens else 0
    prefix = ""
    for raw in raw_words:
        count = len(clean(raw))
        if not count:
            if words:
                words[-1]["text"] += " " + raw
            else:
                prefix += raw + " "
            continue

        first = tokens[index]
        while count > remaining:
            count -= remaining
            index += 1
            remaining = len(tokens[index]["text"])
        last = tokens[index]
        word_start = min(end, max(start, first["start"]))
        word_end = min(end, max(word_start, last["end"]))
        words.append({"text": prefix + raw, "start": word_start - start, "end": word_end - start})
        prefix = ""
        remaining -= count
        if not remaining:
            index += 1
            remaining = len(tokens[index]["text"]) if index < len(tokens) else 0
    return words


def main():
    root, audio, output, context = sys.argv[1:]
    root = Path(root)
    result = transcribe(
        audio,
        model=str(root / "model"),
        forced_aligner=str(root / "aligner"),
        language="Korean",
        context=context,
        return_timestamps=True,
        return_chunks=True,
    )
    segments = result.segments or []
    offset = 0
    chunks = []
    for chunk in result.chunks or []:
        text = chunk["text"].strip()
        tokens = ForcedAlignTextProcessor.tokenize_text(text, "Korean") if text else []
        aligned = segments[offset:offset + len(tokens)]
        offset += len(tokens)
        if [item["text"] for item in aligned] != tokens:
            raise ValueError("Qwen returned incomplete word timings")
        start, end = chunk["start"], chunk["end"]
        words = timed_words(text, aligned, start, end)
        chunks.append({
            "id": chunk["chunk_index"],
            "start": start,
            "end": end,
            "text": text,
            "words": words,
            "truncated": chunk["truncated"],
        })
    if offset != len(segments):
        raise ValueError("Qwen returned extra word timings")
    Path(output).write_text(json.dumps(chunks, ensure_ascii=False, allow_nan=False), encoding="utf-8")


if __name__ == "__main__":
    main()
