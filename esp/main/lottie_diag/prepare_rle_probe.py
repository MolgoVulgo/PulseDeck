#!/usr/bin/env python3
"""test_002-4-11: isolate ThorVG malloc diagnostic from ESP-IDF bridge/linkage.

Commands:
  --self-test
  --stage [--work-root /tmp/fresh-root]
  --instrument [--work-root /tmp/staged-root]

No network, package install, compilation, flash, or repository mutation.
Stop on every mismatch; instrument ONLY the managed ThorVG of an isolated project.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

REFERENCE_RAIN_PREPARER_SHA = "2cc62d46762ce4f658e97f4122db975ca71ae9692b7c37b7dae6d9d070ecf79e"
REFERENCE_RAIN_DEMO_SHA = "04c1c94e38ffcdb8f9daf0272c8bfa5fc84c84b0063a3d7f231f0dcb85c37e31"
DEFAULT_WORK_ROOT = Path("/tmp/pulsedeck_external_lottie_rle_probe_printf")
EXPECTED_THORVG_VERSION = 'espressif/thorvg: "==0.15.16"'
PROBE_MARKER = "PD_RLE_MEMPROBE_002_4_11"
EXPECTED_THORVG_SHA = "ca006d62578122e800b0a0e89e1e09d66ae6c8f322f34d28a9dcbba5c0e3e459"

# Deliberately match exact original release source: no fuzzy source modifications.
ALLOC_ANCHOR = """    if (reqSize > cellPool->size) {
        cellPool->size = ((reqSize + (reqSize >> 2)) / sizeof(SwCell)) * sizeof(SwCell);
        free(cellPool->buffer);
        cellPool->buffer = (SwCell*)malloc(cellPool->size);
    }

    //Init Cells
"""

ALLOC_PATCH = """    if (reqSize > cellPool->size) {
        const uint32_t pd_old_size = cellPool->size;
        cellPool->size = ((reqSize + (reqSize >> 2)) / sizeof(SwCell)) * sizeof(SwCell);
        free(cellPool->buffer);
        // No cross-library symbol and no ESP-IDF header: libc printf/malloc only.
        // Output is flushed before the allocation, and again before abort on NULL.
        std::printf("PD_RLE_ALLOC_BEGIN tid=%u req=%u old=%u new=%u region=%ux%u\\n",
                    tid, (unsigned)reqSize, (unsigned)pd_old_size,
                    (unsigned)cellPool->size, (unsigned)renderRegion.w(),
                    (unsigned)renderRegion.h());
        std::fflush(stdout);
        cellPool->buffer = (SwCell*)malloc(cellPool->size);
        std::printf("PD_RLE_ALLOC_RESULT tid=%u req=%u old=%u new=%u ptr=%p\\n",
                    tid, (unsigned)reqSize, (unsigned)pd_old_size,
                    (unsigned)cellPool->size, (void*)cellPool->buffer);
        std::fflush(stdout);
        if (!cellPool->buffer) {
            std::printf("PD_RLE_ALLOC_NULL tid=%u req=%u new=%u\\n",
                        tid, (unsigned)reqSize, (unsigned)cellPool->size);
            std::fflush(stdout);
            std::abort(); // Explicit diagnostic rather than hidden NULL store.
        }
    }
    if (!cellPool->buffer) {
        std::printf("PD_RLE_BUFFER_NULL tid=%u req=%u current=%u\\n",
                    tid, (unsigned)reqSize, (unsigned)cellPool->size);
        std::fflush(stdout);
        std::abort();
    }

    //Init Cells
"""

INCLUDES = """#include <cstdio>
#include <cstdlib>
"""


def sha(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def require_file(path: Path) -> Path:
    if not path.is_file() or path.is_symlink():
        raise ValueError(f"Missing, unsafe or symlinked source: {path}")
    return path


def transform_source(text: str) -> str:
    if "PD_RLE_MEMPROBE_002_4_9" in text or PROBE_MARKER in text:
        raise ValueError("ThorVG source already instrumented")
    if text.count(ALLOC_ANCHOR) != 1:
        raise ValueError("ThorVG 0.15.16 rleRender allocation anchor mismatch; STOP, do not guess")
    if not text.count("SwRle* rleRender(SwRle* rle, const SwOutline* outline") == 1:
        raise ValueError("ThorVG source missing required rleRender function")
    # Make the instrumentation's scope auditable and safe.
    return (f"// {PROBE_MARKER} -- isolated diagnostic, NOT production.\n" + INCLUDES
            + text.replace(ALLOC_ANCHOR, ALLOC_PATCH, 1))


def workspace_dir(root: Path) -> Path:
    return root.resolve() / 'rain_only' / 'full'


def stage(esp: Path, root: Path) -> None:
    esp = esp.resolve(strict=True)
    root = root.resolve()
    dest = workspace_dir(root)
    if dest.exists():
        raise ValueError(f"Refuse to overwrite previously staged project: {dest}")
    if root == esp or root in esp.parents or esp in root.parents:
        raise ValueError("Root must be completely outside the PulseDeck repository")
    ref = require_file(esp / 'main/lottie_diag/prepare_three_icons.py')
    demo = require_file(esp / 'main/lottie_diag/three_icons_demo.c')
    if sha(ref.read_bytes()) != REFERENCE_RAIN_PREPARER_SHA:
        raise ValueError("rain_only preparer SHA changed; do not substitute another baseline")
    if sha(demo.read_bytes()) != REFERENCE_RAIN_DEMO_SHA:
        raise ValueError("rain_only demo SHA changed; do not substitute another baseline")
    subprocess.run([sys.executable, str(ref), '--mode', 'rain_only', '--esp-dir', str(esp),
                    '--work-root', str(root)], check=True)
    print(f"STAGED_RLE_PROBE workspace={dest} mode=rain_only; original Meteocons JSON; 64x64; 33ms/frame")
    print("NO source modification in repo, NO dependency installation/build/flash")
    print(f"NEXT: cd {dest} && idf.py reconfigure   # only with already available dependencies")
    print(f"THEN: python3 {esp / 'main/lottie_diag/prepare_rle_probe.py'} --instrument --work-root {root}")
    print(f"THEN: cd {dest} && idf.py build; validate serial port; flash/monitor")


def instrument(root: Path) -> None:
    root = root.resolve(strict=True)
    # Never instrument the user's real repository, even if --work-root is misused.
    if not root.is_relative_to(Path('/tmp').resolve()) or root == Path('/tmp'):
        raise ValueError("Only an isolated test project underneath /tmp may be instrumented")
    ws = workspace_dir(root)
    require_file(ws / 'main/CMakeLists.txt')
    cmake = (ws / 'main/CMakeLists.txt').read_text()
    if cmake.count('PD_THREE_TEST_VARIANT=1') != 1 or cmake.count('espressif__esp_lv_lottie_player') != 1:
        raise ValueError('Not the independently staged rain_only Espressif player project')
    manifest = require_file(ws / 'main/idf_component.yml').read_text()
    if EXPECTED_THORVG_VERSION not in manifest or 'espressif/esp_lv_lottie_player: "==0.1.0~1"' not in manifest:
        raise ValueError('Pinned ThorVG/Espressif player versions differ')
    component = ws / 'managed_components/espressif__thorvg'
    if not component.is_dir() or component.is_symlink():
        raise ValueError('ThorVG managed component not resolved; execute idf.py reconfigure first')
    candidates = list(component.rglob('tvgSwRle.cpp'))
    if len(candidates) != 1:
        raise ValueError(f"Expected exactly one ThorVG tvgSwRle.cpp, found {len(candidates)}")
    src = require_file(candidates[0])
    if not src.resolve().is_relative_to(component.resolve()):
        raise ValueError('Resolved ThorVG file escapes the isolated managed component')
    before = src.read_bytes()
    if sha(before) != EXPECTED_THORVG_SHA:
        raise ValueError(f"ThorVG source SHA mismatch: expected {EXPECTED_THORVG_SHA}; got {sha(before)}")
    # Preserve original source bytes; modify only isolated ThorVG under /tmp.
    source_text = before.decode('utf-8')
    patched = transform_source(source_text).encode('utf-8')
    marker_dir = ws / '_pd_rle_probe'
    if marker_dir.exists():
        raise ValueError('Refusing to overwrite prior instrumentation/backup')
    marker_dir.mkdir()
    (marker_dir / 'tvgSwRle.cpp.original').write_bytes(before)
    src.write_bytes(patched)
    record = {'source': str(src), 'before_sha256': sha(before),
              'after_sha256': sha(patched), 'marker': PROBE_MARKER,
              'test_mode': 'rain_only', 'thorvg_version': '0.15.16',
              'logging': 'libc printf (no bridge, no ESP-IDF headers, no CMake changes)'}
    (marker_dir / 'instrumentation.json').write_text(json.dumps(record, indent=2) + '\n')
    if src.read_bytes() != patched:
        raise ValueError('Instrumented ThorVG source mismatch after write')
    print('RLE_INSTRUMENTED', json.dumps(record, sort_keys=True))
    print('Now: idf.py build, then flash/monitor only if build successful. Stop at first NULL/abort/panic.')


def self_test() -> None:
    fake = ('// sample\nSwRle* rleRender(SwRle* rle, const SwOutline* outline, '
            'const SwBBox& renderRegion, SwMpool* mpool, unsigned tid, bool antiAlias)\n{\n'
            + ALLOC_ANCHOR + '\n}\n')
    out = transform_source(fake)
    for expected in (PROBE_MARKER, 'PD_RLE_ALLOC_BEGIN', 'PD_RLE_ALLOC_RESULT',
                     'PD_RLE_ALLOC_NULL', 'PD_RLE_BUFFER_NULL', 'std::printf',
                     'std::fflush(stdout)', 'std::abort()',
                     'cellPool->buffer = (SwCell*)malloc(cellPool->size);'):
        assert expected in out, expected
    assert 'esp_heap_caps.h' not in out
    assert 'pd_rle_probe_log' not in out
    assert 'heap_caps_get_free_size' not in out
    assert 'pd_rle_heap_bridge.c' not in out
    assert out.count('cellPool->buffer = (SwCell*)malloc(cellPool->size);') == 1
    for bad in (fake.replace('malloc(cellPool->size)', 'calloc(1, cellPool->size)'), out):
        try:
            transform_source(bad)
        except ValueError:
            pass
        else:
            raise AssertionError('Expected fail closed for mismatched/already instrumented source')
    print('SELF_TEST_PASS: no cross-library linker symbol; libc printf with explicit flush and NULL guard')


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument('--stage', action='store_true')
    mode.add_argument('--instrument', action='store_true')
    mode.add_argument('--self-test', action='store_true')
    ap.add_argument('--esp-dir', type=Path, default=Path(__file__).resolve().parents[2])
    ap.add_argument('--work-root', type=Path, default=DEFAULT_WORK_ROOT)
    opts = ap.parse_args()
    if opts.self_test:
        self_test()
    elif opts.stage:
        stage(opts.esp_dir, opts.work_root)
    else:
        instrument(opts.work_root)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, UnicodeDecodeError, subprocess.CalledProcessError) as exc:
        print('RLE_PROBE_ERROR:', exc, file=sys.stderr)
        sys.exit(2)
