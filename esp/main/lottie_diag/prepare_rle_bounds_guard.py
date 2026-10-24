#!/usr/bin/env python3
"""test_002-4-12: isolated ThorVG RLE region guard, rain_only hardware experiment.

Does not change the repository's ThorVG or any weather JSON. Only instrument a
fresh /tmp ESP-IDF workspace created using the already validated rain_only
preparer. This is an experimental guard, NOT a production engine upgrade.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

RAIN_PREPARER_SHA = '2cc62d46762ce4f658e97f4122db975ca71ae9692b7c37b7dae6d9d070ecf79e'
RAIN_DEMO_SHA = '04c1c94e38ffcdb8f9daf0272c8bfa5fc84c84b0063a3d7f231f0dcb85c37e31'
EXPECTED_RLE_SHA = 'ca006d62578122e800b0a0e89e1e09d66ae6c8f322f34d28a9dcbba5c0e3e459'
DEFAULT_ROOT = Path('/tmp/pulsedeck_external_lottie_rle_guard')
MARKER = 'PD_RLE_BOUNDS_GUARD_002_4_12'

# Exactly pinned to Espressif ThorVG ==0.15.16; no fuzzy patches or private paths.
FUNCTION_ANCHOR = """SwRle* rleRender(SwRle* rle, const SwOutline* outline, const SwBBox& renderRegion, SwMpool* mpool, unsigned tid, bool antiAlias)
{
    if (!outline) return nullptr;
  
    RleWorker rw;
"""
FUNCTION_PATCH = """SwRle* rleRender(SwRle* rle, const SwOutline* outline, const SwBBox& renderRegion, SwMpool* mpool, unsigned tid, bool antiAlias)
{
    if (!outline) return nullptr;

    // PD_RLE_BOUNDS_GUARD_002_4_12: invalid region must never enter unsigned RLE size arithmetic.
    const int32_t pd_region_w = renderRegion.w();
    const int32_t pd_region_h = renderRegion.h();
    if (pd_region_w <= 0 || pd_region_h <= 0) {
        std::printf("PD_RLE_SKIP_INVALID tid=%u width=%ld height=%ld min=(%ld,%ld) max=(%ld,%ld)\\n",
                    tid, (long)pd_region_w, (long)pd_region_h,
                    (long)renderRegion.min.x, (long)renderRegion.min.y,
                    (long)renderRegion.max.x, (long)renderRegion.max.y);
        std::fflush(stdout);
        return nullptr;
    }

    RleWorker rw;
"""
ALLOC_ANCHOR = """    if (reqSize > cellPool->size) {
        cellPool->size = ((reqSize + (reqSize >> 2)) / sizeof(SwCell)) * sizeof(SwCell);
        free(cellPool->buffer);
        cellPool->buffer = (SwCell*)malloc(cellPool->size);
    }

    //Init Cells
"""
ALLOC_PATCH = """    if (reqSize > cellPool->size) {
        // Preserve the renderer's original calculation; defend against wrap and malloc failure.
        const uint32_t pd_new_size = ((reqSize + (reqSize >> 2)) / sizeof(SwCell)) * sizeof(SwCell);
        if (pd_new_size < reqSize || pd_new_size == 0) {
            std::printf("PD_RLE_SIZE_OVERFLOW tid=%u req=%u candidate=%u\\n",
                        tid, (unsigned)reqSize, (unsigned)pd_new_size);
            std::fflush(stdout);
            return nullptr;
        }
        free(cellPool->buffer);
        cellPool->buffer = (SwCell*)malloc(pd_new_size);
        if (!cellPool->buffer) {
            cellPool->size = 0; // permit a later attempt instead of a stale nonzero size.
            std::printf("PD_RLE_ALLOC_FAILED tid=%u requested=%u width=%ld height=%ld\\n",
                        tid, (unsigned)pd_new_size, (long)pd_region_w, (long)pd_region_h);
            std::fflush(stdout);
            return nullptr;
        }
        cellPool->size = pd_new_size;
    }
    if (!cellPool->buffer) {
        std::printf("PD_RLE_BUFFER_NULL tid=%u current=%u\\n", tid, (unsigned)cellPool->size);
        std::fflush(stdout);
        return nullptr;
    }

    //Init Cells
"""


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def safe_file(path: Path) -> Path:
    if not path.is_file() or path.is_symlink():
        raise ValueError(f'Missing, invalid or symlinked source: {path}')
    return path


def transform(text: str) -> str:
    if 'PD_RLE_MEMPROBE_002_4_11' in text or MARKER in text or 'PD_RLE_MEMPROBE_002_4_9' in text:
        raise ValueError('Source already patched or instrumented: refusing reuse')
    if text.count(FUNCTION_ANCHOR) != 1 or text.count(ALLOC_ANCHOR) != 1:
        raise ValueError('Expected ThorVG 0.15.16 source anchors not matched exactly; STOP')
    return ('// ' + MARKER + ' -- isolated rain_only test, not a production fix.\n'
            '#include <cstdio>\n'
            + text.replace(FUNCTION_ANCHOR, FUNCTION_PATCH, 1)
                  .replace(ALLOC_ANCHOR, ALLOC_PATCH, 1))


def ws_path(root: Path) -> Path:
    return root.resolve() / 'rain_only' / 'full'


def stage(esp: Path, root: Path) -> None:
    esp = esp.resolve(strict=True)
    root = root.resolve()
    if root == esp or root in esp.parents or esp in root.parents:
        raise ValueError('Test workspace must be outside the repository')
    if not root.is_relative_to(Path('/tmp').resolve()) or root == Path('/tmp'):
        raise ValueError('Staging must remain in a dedicated /tmp subtree')
    if ws_path(root).exists():
        raise ValueError(f'Refusing to overwrite an existing workspace: {ws_path(root)}')
    ref = safe_file(esp/'main/lottie_diag/prepare_three_icons.py')
    demo = safe_file(esp/'main/lottie_diag/three_icons_demo.c')
    if sha(ref.read_bytes()) != RAIN_PREPARER_SHA or sha(demo.read_bytes()) != RAIN_DEMO_SHA:
        raise ValueError('Reference rain_only preparer/demo SHA mismatch; STOP')
    subprocess.run([sys.executable, str(ref), '--mode', 'rain_only',
                    '--esp-dir', str(esp), '--work-root', str(root)], check=True)
    print(f'RLE_GUARD_STAGED workspace={ws_path(root)}')
    print('Next: idf.py reconfigure in workspace, then --instrument from the repository')


def instrument(root: Path) -> None:
    root = root.resolve(strict=True)
    if not root.is_relative_to(Path('/tmp').resolve()) or root == Path('/tmp'):
        raise ValueError('Only a dedicated isolated workspace under /tmp may be modified')
    ws = ws_path(root)
    cmake = safe_file(ws/'main/CMakeLists.txt').read_text()
    if cmake.count('PD_THREE_TEST_VARIANT=1') != 1 or cmake.count('espressif__esp_lv_lottie_player') != 1:
        raise ValueError('Project is not the expected rain_only Espressif staging')
    manifest = safe_file(ws/'main/idf_component.yml').read_text()
    if 'espressif/thorvg: "==0.15.16"' not in manifest or 'espressif/esp_lv_lottie_player: "==0.1.0~1"' not in manifest:
        raise ValueError('Component versions changed; STOP')
    component = ws/'managed_components/espressif__thorvg'
    if not component.is_dir() or component.is_symlink():
        raise ValueError('ThorVG managed component missing; idf.py reconfigure first')
    sources = list(component.rglob('tvgSwRle.cpp'))
    if len(sources) != 1:
        raise ValueError(f'Expected exactly one tvgSwRle.cpp; found {len(sources)}')
    src = safe_file(sources[0])
    if not src.resolve().is_relative_to(component.resolve()):
        raise ValueError('Unexpected ThorVG source path')
    original = src.read_bytes()
    if sha(original) != EXPECTED_RLE_SHA:
        raise ValueError(f'ThorVG SHA mismatch, STOP: {sha(original)}')
    patched = transform(original.decode('utf-8')).encode('utf-8')
    backup_dir = ws/'_pd_rle_guard'
    if backup_dir.exists():
        raise ValueError('Already instrumented: refusing overwrite')
    backup_dir.mkdir()
    (backup_dir/'tvgSwRle.cpp.original').write_bytes(original)
    src.write_bytes(patched)
    meta = {'marker': MARKER, 'target': str(src), 'before_sha256': sha(original),
            'after_sha256': sha(patched), 'test_profile':'rain_only',
            'guard':'skip region when width<=0 or height<=0; detect size overflow and malloc NULL'}
    (backup_dir/'guard.json').write_text(json.dumps(meta, indent=2)+'\n')
    if src.read_bytes() != patched:
        raise ValueError('Post-instrumentation SHA/content mismatch')
    print('RLE_GUARD_INSTRUMENTED '+json.dumps(meta, sort_keys=True))
    print('Next: idf.py build; verify physical port; flash/monitor only if build successful')


def self_test() -> None:
    fake = ('// ThorVG source\n'+FUNCTION_ANCHOR+'...\n'+ALLOC_ANCHOR+'}\n')
    out = transform(fake)
    assert out.count('PD_RLE_SKIP_INVALID') == 1
    assert out.count('PD_RLE_ALLOC_FAILED') == 1
    assert out.count('PD_RLE_SIZE_OVERFLOW') == 1
    assert 'if (pd_region_w <= 0 || pd_region_h <= 0)' in out
    assert out.index('PD_RLE_SKIP_INVALID') < out.index('if (reqSize > cellPool->size)')
    assert 'pd_rle_probe_log' not in out and 'esp_heap_caps.h' not in out
    assert out.count('malloc(pd_new_size)') == 1
    for bad in (out, fake.replace('return nullptr;','return false;',1), fake.replace('malloc(cellPool->size)','calloc(1, cellPool->size)')):
        try:
            transform(bad)
        except ValueError:
            pass
        else:
            raise AssertionError('Unexpected acceptance of changed/already-patched source')
    print('SELF_TEST_PASS: strict anchors, signed region guard, allocation checks, libc logging only')


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument('--self-test', action='store_true')
    mode.add_argument('--stage', action='store_true')
    mode.add_argument('--instrument', action='store_true')
    ap.add_argument('--esp-dir', type=Path, default=Path(__file__).resolve().parents[2])
    ap.add_argument('--work-root', type=Path, default=DEFAULT_ROOT)
    args = ap.parse_args()
    if args.self_test:
        self_test()
    elif args.stage:
        stage(args.esp_dir, args.work_root)
    else:
        instrument(args.work_root)

if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, UnicodeDecodeError, subprocess.CalledProcessError) as exc:
        print('RLE_GUARD_ERROR:', exc, file=sys.stderr)
        sys.exit(2)
