#!/usr/bin/env python3
"""test_002-4-14: C1 clear-day, C2/C3 partly-cloudy-day-rain, with tested RLE guard.

The 002-4-8 staging and 002-4-12 ThorVG guard are SHA-pinned. Changes only
isolated /tmp staging; repo-generated SquareLine and JSON are never modified.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import runpy
import subprocess
import sys

PATCH_ID = 'test_002-4-14'
DEFAULT_ROOT = Path('/tmp/pulsedeck_external_lottie_rle_guard_double_partly_rain')
THREE_PREPARER_SHA = '7e0a6a149dcb78d5d4477c425d29e96d6fc67726f51fc37417ea14e00d97561c'
THREE_DEMO_SHA = '33f3974faa522fddc11ecf2d24022f11c1895e5aa723097b76cb184b1927f754'
GUARD_SCRIPT_SHA = '009097c3eaacb480d7203f32eac7c8d8f610556e6d472fd59d1b0e0f5abe7b5a'
THORVG_ORIGINAL_SHA = 'ca006d62578122e800b0a0e89e1e09d66ae6c8f322f34d28a9dcbba5c0e3e459'
CLEAR_SHA = '930084453639864f519a4e2d2b791b042ac94b67816614144ff28e471106fc24'
COMBINED_SHA = '9d286ec957ed396110e0515c6bc431238a8ff6b38b0d277dba9c7b918cdfd4f1'
COMBINED_SIZE = 32197


def sha(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def require_file(path: Path, expected_sha: str | None = None) -> Path:
    if not path.is_file() or path.is_symlink():
        raise ValueError(f'Missing, invalid or symlinked file: {path}')
    if expected_sha is not None and sha(path.read_bytes()) != expected_sha:
        raise ValueError(f'SHA mismatch: {path}; STOP')
    return path


def validated(esp_dir: Path, root: Path):
    esp = esp_dir.resolve(strict=True)
    dst = root.resolve()
    if not dst.is_relative_to(Path('/tmp').resolve()) or dst == Path('/tmp'):
        raise ValueError('Isolated destination must be under a dedicated /tmp subtree')
    if esp == dst or esp in dst.parents or dst in esp.parents:
        raise ValueError('Staged workspace overlaps repo')
    script_dir = esp / 'main/lottie_diag'
    preparer = require_file(script_dir/'prepare_clear_fog_partly_rain.py', THREE_PREPARER_SHA)
    demo = require_file(script_dir/'clear_fog_partly_rain_demo.c', THREE_DEMO_SHA)
    guard = require_file(script_dir/'prepare_rle_bounds_guard.py', GUARD_SCRIPT_SHA)
    assets_dir = esp/'ui/assets/meteocons/fill'
    require_file(assets_dir/'clear-day.json', CLEAR_SHA)
    combined = require_file(assets_dir/'partly-cloudy-day-rain.json', COMBINED_SHA)
    if combined.stat().st_size != COMBINED_SIZE:
        raise ValueError('Original composed asset size has changed')
    # Original preparer also expects fog to be present, but we REMOVE it from staged arrays.
    return esp, dst, preparer, demo, guard, assets_dir


EXTERNS_FOG = '''extern const uint8_t pd_three_fog_json[];
extern const size_t pd_three_fog_len;
extern const uint32_t pd_three_fog_frames;
extern const uint32_t pd_three_fog_fps_milli;
'''
FOG_ENTRY = '''        {"fog", pd_three_fog_json, pd_three_fog_len,
         pd_three_fog_frames, pd_three_fog_fps_milli},'''
PARTLY_ENTRY = '''        {"partly-cloudy-day-rain", pd_three_partly_cloudy_day_rain_json,
         pd_three_partly_cloudy_day_rain_len,
         pd_three_partly_cloudy_day_rain_frames,
         pd_three_partly_cloudy_day_rain_fps_milli},'''


def change_demo(raw: bytes) -> bytes:
    src = raw.decode('utf-8')
    replacements = [
        ('C1 clear-day, C2 fog, C3 partly-cloudy-day-rain',
         'C1 clear-day, C2/C3 partly-cloudy-day-rain'),
        (EXTERNS_FOG, ''),
        ('3 independent original JSON files', '2 original JSON files, 3 independent widgets'),
        (FOG_ENTRY, PARTLY_ENTRY),
        ('C1=clear-day C2=fog C3=partly-cloudy-day-rain',
         'C1=clear-day C2=partly-cloudy-day-rain C3=partly-cloudy-day-rain'),
    ]
    for before, after in replacements:
        if src.count(before) != 1:
            raise ValueError(f'Unexpected demo template anchor, count={src.count(before)}: {before[:70]}')
        src = src.replace(before, after, 1)
    if 'pd_three_fog_' in src or 'C2=fog' in src or '"fog"' in src:
        raise ValueError('Fog remains in staged demo')
    if src.count('{"partly-cloudy-day-rain", pd_three_partly_cloudy_day_rain_json,') != 2 or 'ui_test_Container1, ui_test_Container2, ui_test_Container3' not in src:
        raise ValueError('Unexpected two-composed demo mapping')
    return src.encode('utf-8')


def generate_two_assets(preparer: Path, assets_dir: Path) -> bytes:
    module = runpy.run_path(str(preparer), run_name='pd_reference_002_4_8')
    read_asset = module['read_asset']
    clear = read_asset(assets_dir/'clear-day.json', CLEAR_SHA)
    composed = read_asset(assets_dir/'partly-cloudy-day-rain.json', COMBINED_SHA)
    data = module['create_arrays']({'clear-day': clear, 'partly-cloudy-day-rain': composed})
    if b'pd_three_fog_' in data or b'pd_three_clear_day_json' not in data or b'pd_three_partly_cloudy_day_rain_json' not in data:
        raise ValueError('Unexpected staged JSON symbol set')
    if data.count(b'const uint8_t pd_three_') != 2:
        raise ValueError('Expected two embedded JSON sources')
    return data


def stage(esp_dir: Path, root: Path) -> None:
    esp, dst, preparer, demo, _, assets = validated(esp_dir, root)
    ws = dst/'full'
    if ws.exists():
        raise ValueError(f'Refusing to overwrite prior workspace: {ws}')
    # Prepare/validate all three original symbols and assets using the already proven
    # pinned generator, then remove fog only in the isolated C staging.
    subprocess.run([sys.executable, str(preparer), '--esp-dir', str(esp), '--work-root', str(dst)], check=True)
    staged_demo = require_file(ws/'main/espressif_player_demo.c', THREE_DEMO_SHA)
    staged_arrays = require_file(ws/'main/pd_three_json.c')
    demo_bytes = change_demo(staged_demo.read_bytes())
    array_bytes = generate_two_assets(preparer, assets)
    staged_demo.write_bytes(demo_bytes)
    staged_arrays.write_bytes(array_bytes)
    if staged_demo.read_bytes() != demo_bytes or staged_arrays.read_bytes() != array_bytes:
        raise ValueError('Staged output mismatch')
    print('PD_214_STAGED', ws, 'C1=clear-day C2=C3=partly-cloudy-day-rain')
    print('Two unique original JSON arrays, three independent LVGL widgets and PSRAM buffers')
    print('Next: idf.py reconfigure; then --instrument; then build, flash, monitor')


def instrument(esp_dir: Path, root: Path) -> None:
    esp, dst, preparer, demo, guard, assets = validated(esp_dir, root)
    ws = dst/'full'
    require_file(ws/'main/espressif_player_demo.c')
    if sha((ws/'main/espressif_player_demo.c').read_bytes()) != sha(change_demo(demo.read_bytes())):
        raise ValueError('Staged demo changed unexpectedly')
    if sha(require_file(ws/'main/pd_three_json.c').read_bytes()) != sha(generate_two_assets(preparer, assets)):
        raise ValueError('Staged two-assets JSON changed unexpectedly')
    cmake = require_file(ws/'main/CMakeLists.txt').read_text()
    if cmake.count('"pd_three_json.c"') != 1 or cmake.count('"espressif_player_demo.c"') != 1:
        raise ValueError('Staged build sources mismatch')
    manifest = require_file(ws/'main/idf_component.yml').read_text()
    if 'espressif/thorvg: "==0.15.16"' not in manifest or 'espressif/esp_lv_lottie_player: "==0.1.0~1"' not in manifest:
        raise ValueError('Unexpected component versions')
    component = ws/'managed_components/espressif__thorvg'
    if not component.is_dir() or component.is_symlink():
        raise ValueError('Managed ThorVG missing, run idf.py reconfigure first')
    matches = list(component.rglob('tvgSwRle.cpp'))
    if len(matches) != 1:
        raise ValueError(f'Expected one ThorVG renderer, got {len(matches)}')
    cpp = require_file(matches[0], THORVG_ORIGINAL_SHA)
    if not cpp.resolve().is_relative_to(component.resolve()):
        raise ValueError('ThorVG source escapes managed components')
    backup_dir = ws/'_pd_rle_guard_double_partly_rain'
    if backup_dir.exists():
        raise ValueError('Already instrumented; refusing overwrite')
    guard_module = runpy.run_path(str(guard), run_name='pd_guard_002_4_12')
    original = cpp.read_bytes()
    patched = guard_module['transform'](original.decode('utf-8')).encode('utf-8')
    for marker in (b'PD_RLE_SKIP_INVALID', b'PD_RLE_ALLOC_FAILED', b'PD_RLE_SIZE_OVERFLOW', b'PD_RLE_BUFFER_NULL'):
        if patched.count(marker) != 1:
            raise ValueError(f'Guard marker mismatch {marker!r}')
    backup_dir.mkdir()
    (backup_dir/'tvgSwRle.cpp.original').write_bytes(original)
    cpp.write_bytes(patched)
    meta = {'patch': PATCH_ID,
            'mapping': {'ui_test_Container1': 'clear-day',
                        'ui_test_Container2': 'partly-cloudy-day-rain',
                        'ui_test_Container3': 'partly-cloudy-day-rain'},
            'thorvg_before_sha256': sha(original), 'thorvg_after_sha256': sha(patched),
            'guard_sha256': GUARD_SCRIPT_SHA}
    (backup_dir/'instrumentation.json').write_text(json.dumps(meta, indent=2)+'\n')
    if cpp.read_bytes() != patched:
        raise ValueError('Instrumented ThorVG changed')
    print('PD_214_INSTRUMENTED', json.dumps(meta, sort_keys=True))


def self_test(esp_dir: Path) -> None:
    _, _, preparer, demo, guard, _ = validated(esp_dir, DEFAULT_ROOT)
    assert change_demo(demo.read_bytes()).count(b'{"partly-cloudy-day-rain", pd_three_partly_cloudy_day_rain_json,') == 2
    guard_module = runpy.run_path(str(guard), run_name='pd_guard_002_4_12_selftest')
    guard_module['self_test']()
    example = {'v': '5.7.0', 'w': 128, 'h': 128, 'fr': 60, 'ip': 0,
               'op': 360, 'layers': [{'ty': 4}]}
    mod = runpy.run_path(str(preparer), run_name='pd_arrays_002_4_8_selftest')
    raw = json.dumps(example).encode()
    sample = mod['create_arrays']({'clear-day': (raw, example), 'partly-cloudy-day-rain': (raw, example)})
    assert b'pd_three_fog_' not in sample and sample.count(b'const uint8_t pd_three_') == 2
    assert 'pd_rle_probe_log' not in guard_module['transform'](guard_module['FUNCTION_ANCHOR']+'\n'+guard_module['ALLOC_ANCHOR'])
    print('SELF_TEST_PASS: C1 clear-day, C2/C3 partly rain, 2 unique sources, original 002-4-12 guard')


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    action = ap.add_mutually_exclusive_group(required=True)
    action.add_argument('--self-test', action='store_true')
    action.add_argument('--stage', action='store_true')
    action.add_argument('--instrument', action='store_true')
    ap.add_argument('--esp-dir', type=Path, default=Path(__file__).resolve().parents[2])
    ap.add_argument('--work-root', type=Path, default=DEFAULT_ROOT)
    args = ap.parse_args()
    try:
        if args.self_test:
            self_test(args.esp_dir)
        elif args.stage:
            stage(args.esp_dir, args.work_root)
        else:
            instrument(args.esp_dir, args.work_root)
    except (OSError, ValueError, KeyError, AssertionError, UnicodeDecodeError, subprocess.CalledProcessError) as err:
        print('PD_214_ERROR:', err, file=sys.stderr)
        sys.exit(2)


if __name__ == '__main__':
    main()
