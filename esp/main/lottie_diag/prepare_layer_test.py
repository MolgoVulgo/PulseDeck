#!/usr/bin/env python3
"""Prepare an independent build/sdconfig per Meteocons layer test, without flashing."""
import argparse
import hashlib
from pathlib import Path
import shlex

MODES = ('b_only', 'reversed', 'b_reduced', 'split', 'split_long')

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--mode', choices=MODES, required=True)
    parser.add_argument('--esp-dir', type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument('--work-dir', type=Path, default=Path('/tmp/pulsedeck_lottie_layers'))
    args = parser.parse_args()
    esp = args.esp_dir.resolve()
    cfg = (esp / 'sdkconfig').read_bytes()
    for marker in (b'CONFIG_LV_USE_LOTTIE=y', b'CONFIG_SPIRAM_USE_MALLOC=y'):
        if marker not in cfg: raise SystemExit(f'Unsupported baseline sdkconfig: missing {marker!r}')
    directory = args.work_dir.resolve() / args.mode
    directory.mkdir(parents=True, exist_ok=True)
    sdkconfig = directory / 'sdkconfig'
    if not sdkconfig.is_file() or sdkconfig.read_bytes() != cfg:
        sdkconfig.write_bytes(cfg)
    cmd = ['idf.py', '-B', str(directory/'build'), f'-DSDKCONFIG={sdkconfig}',
           f'-DPD_LOTTIE_LAYER_TEST={args.mode}', 'build']
    print('Mode:', args.mode)
    print('sdkconfig unchanged copied to:', sdkconfig, 'sha256:', hashlib.sha256(cfg).hexdigest())
    print('Commands from directory:', esp)
    print('  BUILD: ', shlex.join(cmd))
    print('  FLASH: ', shlex.join(['idf.py', '-B', str(directory/'build'), '-p', '/dev/ttyUSB0', 'flash']))
    print('  MONITOR: ', shlex.join(['idf.py', '-B', str(directory/'build'), '-p', '/dev/ttyUSB0', 'monitor']))
    print('Stop at first panic. Monitor >=160 seconds for split_long; otherwise >=45 seconds.')

if __name__ == '__main__':
    main()
