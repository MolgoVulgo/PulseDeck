#!/usr/bin/env python3
"""Generate diagnostic layer-subset Lottie variants in BUILD directory only.
The original Meteocons JSON is never modified, and full mode uses exact bytes.
"""
import argparse, copy, hashlib, json
from pathlib import Path

def build(source, mode):
    raw = source.read_bytes()
    obj = json.loads(raw.decode("utf-8"))
    layers = obj.get("layers")
    if not isinstance(layers, list) or not layers:
        raise ValueError("missing Lottie layers")
    n = len(layers)
    if mode == "full":
        return raw, n, n
    howmany = {"one": 1, "two": 2, "half": max(1, (n + 1) // 2)}[mode]
    if howmany > n:
        raise ValueError(f"{mode} requires {howmany} layers but file has only {n}")
    obj["layers"] = copy.deepcopy(layers[:howmany])
    obj["nm"] = f"{obj.get('nm', 'Meteocons')} [PulseDeck diagnostic {mode}]"
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode("utf-8"), n, howmany

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", type=Path, required=True)
    ap.add_argument("--variant", choices=("one", "two", "half", "full"), required=True)
    ap.add_argument("--output", type=Path, required=True)
    a = ap.parse_args()
    try:
        data, total, kept = build(a.source, a.variant)
        a.output.parent.mkdir(parents=True, exist_ok=True)
        if not a.output.is_file() or a.output.read_bytes() != data:
            a.output.write_bytes(data)
        print(f"PD_SUITE_JSON variant={a.variant} layers={kept}/{total} bytes={len(data)} sha256={hashlib.sha256(data).hexdigest()}")
        return 0
    except Exception as exc:
        ap.error(str(exc))

if __name__ == "__main__":
    raise SystemExit(main())
