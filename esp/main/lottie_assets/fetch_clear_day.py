#!/usr/bin/env python3
"""Validate and embed *exact* local Meteocons Lottie JSON for PulseDeck test_002.

Uses the Python standard library only. Writes in the CMake binary/build directory,
not in SquareLine or source assets. No network access is needed.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys

MAX_BYTES = 512 * 1024


def validate(raw):
    if not 64 <= len(raw) <= MAX_BYTES:
        raise ValueError(f"unexpected Lottie JSON size: {len(raw)} bytes")
    obj = json.loads(raw.decode("utf-8"))
    if not isinstance(obj, dict):
        raise ValueError("Lottie data must be an object")
    for key in ("v", "w", "h", "fr", "ip", "op", "layers"):
        if key not in obj:
            raise ValueError(f"missing mandatory Lottie key: {key}")
    if not isinstance(obj["layers"], list) or not obj["layers"]:
        raise ValueError("Lottie layers missing/empty")
    fps = float(obj["fr"])
    first = float(obj["ip"])
    last = float(obj["op"])
    if not (1 <= fps <= 120 and 0 <= first < last <= 20000):
        raise ValueError("invalid fps/frame-range")
    if not (1 <= int(obj["w"]) <= 2048 and 1 <= int(obj["h"]) <= 2048):
        raise ValueError("invalid composition size")
    return obj


def main():
    p=argparse.ArgumentParser()
    p.add_argument('--source',type=Path,required=True)
    p.add_argument('--out-c',type=Path,required=True)
    args=p.parse_args()
    args.out_c.parent.mkdir(parents=True,exist_ok=True)
    try:
        raw=args.source.read_bytes()
        obj=validate(raw)
        print(f"Meteocons Lottie: local source {args.source}")
        h=hashlib.sha256(raw).hexdigest()
        fps_milli=round(float(obj['fr'])*1000)
        frames=round(float(obj['op'])-float(obj['ip']))
        print(f"Meteocons clear-day: sha256={h} bytes={len(raw)} fps={obj['fr']} frames={frames} composition={obj['w']}x{obj['h']}")
        # C source contains exact JSON UTF-8 bytes and a terminal NUL.
        src=['/* GENERATED ONLY IN BUILD DIRECTORY; Meteocons (MIT), '+args.source.name+' */',
             '#include <stdint.h>',
             'const uint8_t pd_lottie_clear_day_json[] = {']
        data=raw+b'\0'
        for start in range(0,len(data),16):
            src.append('    '+', '.join(f'0x{x:02x}' for x in data[start:start+16])+',')
        src += ['};',f'const uint32_t pd_lottie_clear_day_json_len = {len(raw)}u;',
                f'const uint32_t pd_lottie_clear_day_fps_milli = {fps_milli}u;',
                f'const uint32_t pd_lottie_clear_day_frames = {frames}u;',
                f'/* SOURCE SHA256: {h} */','']
        out='\n'.join(src)
        if not args.out_c.exists() or args.out_c.read_text()!=out:
            args.out_c.write_text(out)
        return 0
    except Exception as exc:
        print(f"ERROR: Cannot read/validate Meteocons clear-day.json: {exc}",file=sys.stderr)
        print(f"Source: {args.source}; do not replace with placeholder or an unrelated Lottie",file=sys.stderr)
        return 2

if __name__=='__main__':
    raise SystemExit(main())
