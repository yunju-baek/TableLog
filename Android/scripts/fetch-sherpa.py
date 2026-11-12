#!/usr/bin/env python3
"""Fetch the pinned upstream Android runtime; never commit native binaries."""
import argparse
import hashlib
import os
from pathlib import Path
import urllib.request

URL = 'https://github.com/k2-fsa/sherpa-onnx/releases/download/v2.0.1/sherpa-onnx-2.0.1.aar'
SHA256 = 'a8d09d1d32f3eb8520482c6d3d43fae674681c5b050385967c70a3c2c9bf0ee7'


def digest(path):
    with path.open('rb') as f:
        h = hashlib.sha256()
        for data in iter(lambda: f.read(1024 * 1024), b''):
            h.update(data)
        return h.hexdigest()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', required=True, type=Path)
    target = parser.parse_args().output
    if target.exists() and digest(target) == SHA256:
        raise SystemExit(0)
    target.parent.mkdir(parents=True, exist_ok=True)
    partial = target.with_suffix('.part')
    try:
        with urllib.request.urlopen(URL, timeout=60) as source, partial.open('wb') as out:
            while data := source.read(1024 * 1024):
                out.write(data)
            out.flush()
            os.fsync(out.fileno())
        if digest(partial) != SHA256:
            raise RuntimeError('sherpa-onnx checksum mismatch')
        partial.replace(target)
    finally:
        partial.unlink(missing_ok=True)
    print('Verified sherpa-onnx 2.0.1 Android runtime')
