#!/usr/bin/env python3
"""Prepare one isolated diagnostic: rain alone or rain first in the full 3-icon UI.

Uses the validated test_002-4-1 workspace generator. NO download/build/flash or
write to the PulseDeck source is performed. If fog/rain JSON is not installed,
stop explicitly; ask the user before obtaining the pinned Meteocons assets.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

CLEAR_SHA = '930084453639864f519a4e2d2b791b042ac94b67816614144ff28e471106fc24'
REFERENCE_PREPARER_SHA = '4f4bfae2b2d18f249abe2f5a33d50ea19b2092b92da29e3230d32a0423ed33cf'
NAMES = ('clear-day', 'fog', 'rain')
DEFAULT_WORK_ROOT = Path('/tmp/pulsedeck_external_lottie_rain_isolation')
MODE_IDS = {'rain_only': 1, 'rain_first': 2, 'full': 0}


def sha(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def require_file(path: Path) -> Path:
    if not path.is_file() or path.is_symlink():
        raise ValueError(f'missing/unsafe file: {path}')
    return path


def read_asset(path: Path, expected_sha: str | None = None) -> tuple[bytes, dict]:
    raw = require_file(path).read_bytes()
    if not 64 <= len(raw) <= 512 * 1024:
        raise ValueError(f'invalid Lottie JSON size for {path}: {len(raw)}')
    if expected_sha and sha(raw) != expected_sha:
        raise ValueError(f'original clear-day JSON SHA mismatch: {sha(raw)}')
    obj = json.loads(raw.decode('utf-8'))
    if not isinstance(obj, dict) or not isinstance(obj.get('layers'), list) or not obj['layers']:
        raise ValueError(f'invalid or empty Lottie layers: {path}')
    for key in ('v', 'w', 'h', 'fr', 'ip', 'op'):
        if key not in obj:
            raise ValueError(f'Lottie metadata {key} absent: {path}')
    fps = float(obj['fr'])
    frames = float(obj['op']) - float(obj['ip'])
    if not 1 <= fps <= 120 or not 1 <= frames <= 20000:
        raise ValueError(f'invalid Lottie timing: {path}')
    if int(obj['w']) != 128 or int(obj['h']) != 128:
        raise ValueError(f'expected 128x128 Meteocons Fill: {path}')
    # Our test does not provide an image or font provider for externally linked assets.
    if obj.get('assets'):
        raise ValueError(f'embedded/external assets not supported in final three-icon test: {path}')
    return raw, obj


def create_arrays(assets: dict[str, tuple[bytes, dict]]) -> bytes:
    lines = ['/* Generated in /tmp only; exact original local Meteocons JSON bytes. */',
             '#include <stddef.h>', '#include <stdint.h>']
    for name, (raw, obj) in assets.items():
        c_name = name.replace('-', '_')
        lines.append(f'const uint8_t pd_three_{c_name}_json[] = {{')
        data = raw + b'\0'
        for pos in range(0, len(data), 24):
            lines.append('    ' + ', '.join(f'0x{b:02x}' for b in data[pos:pos + 24]) + ',')
        lines += ['};', f'const size_t pd_three_{c_name}_len = {len(raw)}u;',
                  f'const uint32_t pd_three_{c_name}_frames = {round(float(obj["op"]) - float(obj["ip"]))}u;',
                  f'const uint32_t pd_three_{c_name}_fps_milli = {round(float(obj["fr"]) * 1000)}u;',
                  f'/* {name} SHA256={sha(raw)} */']
    return ('\n'.join(lines) + '\n').encode('utf-8')


def make(args):
    esp = args.esp_dir.resolve(strict=True)
    assets_root = args.assets_dir.resolve() if args.assets_dir else esp / 'ui/assets/meteocons/fill'
    dst_root = args.work_root.resolve()
    case_root = dst_root / args.mode
    dst = case_root / 'full'
    if dst.exists():
        raise ValueError(f'test directory already exists; never overwrite: {dst}')
    if dst_root == esp or dst_root in esp.parents or esp in dst_root.parents:
        raise ValueError('work directory must be independent from PulseDeck')
    scripts = esp / 'main/lottie_diag'
    ref = require_file(scripts / 'prepare_espressif_player.py')
    if sha(ref.read_bytes()) != REFERENCE_PREPARER_SHA:
        raise ValueError('reference test_002-4-1 preparer has changed; inspect before migration')
    demo = require_file(scripts / 'three_icons_demo.c')
    ui_h = require_file(esp / 'components/ui/generated/screens/ui_test.h').read_text()
    ui_c = require_file(esp / 'components/ui/generated/screens/ui_test.c').read_text()
    for i in range(1, 4):
        # Use the exact SquareLine custom symbol, including the uppercase C.
        sym = f'ui_test_Container{i}'
        generated = f'ui_test_container{i}'
        if f'extern lv_obj_t * {sym};' not in ui_h:
            raise ValueError(f'SquareLine header lacks exact name {sym}; do not substitute lowercase alias')
        if f'lv_obj_t * {sym};' not in ui_c or f'{sym} = {generated};' not in ui_c:
            raise ValueError(f'SquareLine export lacks creation/assignment for {sym}')
        if f'lv_obj_set_width({generated}, 64)' not in ui_c or f'lv_obj_set_height({generated}, 64)' not in ui_c:
            raise ValueError(f'SquareLine container {sym} is not 64x64; inspect new export')
    assets = {}
    for name in NAMES:
        p = assets_root / (name + '.json')
        if not p.is_file():
            raise ValueError(
                f'{name}.json absent: {p}. Provide ORIGINAL Meteocons @meteocons/lottie@0.1.0 '
                f'Fill JSON locally (read-only) and rerun with --assets-dir. '
                f'Do not use SVG, placeholder or automatic network download.')
        data, meta = read_asset(p, CLEAR_SHA if name == 'clear-day' else None)
        assets[name] = (data, meta)
    # Base preparer enforces baseline SDK, pins the validated Espressif player,
    # copies latest SquareLine to /tmp, and disables native LVGL Lottie.
    subprocess.run([sys.executable, str(ref), '--mode', 'full', '--esp-dir', str(esp),
                    '--work-root', str(case_root)], check=True)
    try:
        main = dst / 'main'
        shutil.copy2(demo, main / 'espressif_player_demo.c')
        (main / 'pd_three_json.c').write_bytes(create_arrays(assets))
        cmake = main / 'CMakeLists.txt'
        code = cmake.read_text()
        if code.count('"pd_external_json.c"') != 1 or code.count('"espressif_player_demo.c"') != 1:
            raise ValueError('isolated CMake does not match validated test_002-4-1 staging')
        # Applied ONLY to the temporary CMake target of this independent build.
        compile_case = MODE_IDS[args.mode]
        cmake.write_text(code.replace('"pd_external_json.c"', '"pd_three_json.c"')
                         + '\n# Diagnostic selector, not a production setting.\n'
                         + 'target_compile_definitions(${COMPONENT_LIB} PRIVATE '
                         + f'PD_THREE_TEST_VARIANT={compile_case})\n')
        # Old staged single-asset C arrays are now unused; remove only the staged copy.
        (main / 'pd_external_json.c').unlink()
    except BaseException:
        shutil.rmtree(dst)
        raise
    print(f'ISOLATION workspace={dst} mode={args.mode} active_icons={1 if args.mode == "rain_only" else 3}')
    print('MAPPING C1=clear-day C2=fog C3=rain unchanged; parent layout precomputed')
    for name, (data, meta) in assets.items():
        duration_ms = round(float(meta['op']) - float(meta['ip'])) * round(2000 / float(meta['fr']))
        print(f'  {name} bytes={len(data)} sha256={sha(data)} fps={meta["fr"]} frames={float(meta["op"])-float(meta["ip"]):g} expected_cycle_ms_approx={duration_ms}')
    print('Player=0.1.0~1 ThorVG=0.15.16 LVGL=9.5.0 UI stack=32768; each active widget uses its own 16KiB PSRAM buffer; speed=50pct')
    print('NO repository edits, NO network, NO build, NO flash. Confirm correct serial port before flash.')
    print('  cd', dst)
    print('  idf.py build')
    print('  idf.py -p /dev/ttyUSB0 flash')
    print('  idf.py -p /dev/ttyUSB0 monitor')
    print('STOP on first panic; rain_only: observe >=60 s, then rain_first: >=180 s if rain_only passed.')


def self_test():
    example = {'v': '5.7.0', 'w': 128, 'h': 128, 'fr': 60,
               'ip': 0, 'op': 360, 'layers': [{'ty': 4}]}
    arrays = create_arrays({'clear-day': (json.dumps(example).encode(), example)})
    assert b'pd_three_clear_day_frames = 360u;' in arrays
    assert b'pd_three_clear_day_fps_milli = 60000u;' in arrays
    assert b'pd_three_clear_day_len' in arrays
    assert MODE_IDS == {'rain_only': 1, 'rain_first': 2, 'full': 0}
    print('SELF_TEST PASS: deterministic C arrays, Lottie metadata, isolation selectors')


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--mode', choices=tuple(MODE_IDS), default='rain_only',
                    help='rain_only then rain_first; full is an optional control')
    ap.add_argument('--esp-dir', type=Path, default=Path(__file__).resolve().parents[2])
    ap.add_argument('--assets-dir', type=Path, help='directory with original fill/*.json (clear-day, fog, rain)')
    ap.add_argument('--work-root', type=Path, default=DEFAULT_WORK_ROOT)
    ap.add_argument('--self-test', action='store_true')
    a = ap.parse_args()
    if a.self_test:
        self_test()
    else:
        make(a)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as e:
        print('FINAL_TEST ERROR:', e, file=sys.stderr)
        sys.exit(2)
