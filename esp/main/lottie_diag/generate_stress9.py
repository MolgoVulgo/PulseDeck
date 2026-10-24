#!/usr/bin/env python3
"""Generate flash-resident byte arrays from nine untouched Lottie JSON fixtures."""
import argparse
import hashlib
import json
from pathlib import Path

ASSETS = [
    'extreme-thunderstorms-extreme-day-sleet',
    'extreme-thunderstorms-overcast-day-snow',
    'extreme-thunderstorms-mostly-clear-day-sleet',
    'extreme-thunderstorms-extreme-night-snow',
    'extreme-thunderstorms-overcast-day-haze',
    'extreme-sleet',
    'extreme-thunderstorms-night-hail',
    'extreme-thunderstorms-night-smoke',
    'overcast-day-fog',
]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--src-dir', required=True)
    ap.add_argument('--out-c', required=True)
    args = ap.parse_args()
    root = Path(args.src_dir)
    out = Path(args.out_c)
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open('w', encoding='ascii') as fp:
        fp.write('#include <stdint.h>\n')
        for i, name in enumerate(ASSETS):
            raw = (root / (name + '.json')).read_bytes()
            doc = json.loads(raw)
            if not isinstance(doc.get('layers'), list) or not doc.get('w') or not doc.get('h'):
                raise ValueError('Invalid Lottie '+name)
            fp.write('const uint8_t pd_stress9_json_%d[] = {\n' % i)
            for offset in range(0, len(raw), 24):
                fp.write('  '+', '.join('0x%02x'%b for b in raw[offset:offset+24])+',\n')
            fp.write('  0x00\n};\n')
            fp.write('const uint32_t pd_stress9_len_%d = %du;\n' % (i,len(raw)))
            print('%d %s bytes=%d sha256=%s' % (i+1,name,len(raw),hashlib.sha256(raw).hexdigest()))

if __name__ == '__main__':
    main()
