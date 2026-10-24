#!/usr/bin/env python3
"""Stage a 50% speed Espressif Lottie playback test in an isolated /tmp project.

The validated PulseDeck demo and original clear-day.json stay unchanged. Neither
this script nor the parent preparer builds, downloads dependencies, or flashes.
"""
from __future__ import annotations
import argparse
import hashlib
from pathlib import Path
import subprocess
import sys

PREPARER_SHA = "4f4bfae2b2d18f249abe2f5a33d50ea19b2092b92da29e3230d32a0423ed33cf"
DEMO_SHA = "7b3c1608b973106f70623c1b3b6a4f91e1c1c4b33d356eb7f09a6c7ce34f4687"
FRAME_DELAY_MS = 33  # 360 frames -> 11,880 ms/cycle vs original ~6,000 ms.

ANCHOR = "    lv_lottie_set_loop_enabled(obj, true);\n"
INSERT = """    /* Half-speed experiment: duration is ~11.88 s for 360 frames.
     * This changes playback timing only; no JSON, scale or output size edits. */
    lv_lottie_set_frame_delay(obj, 33u);
    ESP_LOGI(TAG, "PLAYBACK_SPEED=50pct frame_delay_ms=%lu expected_loop_ms=%lu",
             (unsigned long)lv_lottie_get_frame_delay(obj),
             (unsigned long)(lv_lottie_get_total_frames(obj) * 33u));
"""


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def patch_demo(original: bytes) -> bytes:
    if sha256(original) != DEMO_SHA:
        raise ValueError("Validated test_002-4-1 demo SHA mismatch; abort without modifications")
    source = original.decode("utf-8")
    if source.count(ANCHOR) != 1:
        raise ValueError("Cannot identify unique loop configuration line")
    output = source.replace(ANCHOR, ANCHOR + INSERT, 1)
    if output.count('lv_lottie_set_frame_delay(obj, 33u);') != 1:
        raise ValueError("Half-speed injection missing or duplicated")
    if len(output) <= len(source):
        raise ValueError("Source unexpectedly shortened")
    return output.encode("utf-8")


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--esp-dir", type=Path, default=Path(__file__).resolve().parents[2])
    p.add_argument("--work-root", type=Path, default=Path("/tmp/pulsedeck_external_lottie_half_speed"))
    p.add_argument("--self-test", action="store_true", help="Validate injection with local demo only")
    args = p.parse_args()
    esp = args.esp_dir.resolve(strict=True)
    preparer = esp / "main/lottie_diag/prepare_espressif_player.py"
    demo = esp / "main/lottie_diag/espressif_player_demo.c"
    if not preparer.is_file() or preparer.is_symlink() or sha256(preparer.read_bytes()) != PREPARER_SHA:
        raise ValueError("Validated test_002-4-1 preparer SHA mismatch; abort")
    if not demo.is_file() or demo.is_symlink():
        raise ValueError("Original validated Espressif demo missing or unsafe")
    expected = patch_demo(demo.read_bytes())
    if args.self_test:
        print(f"PASS half-speed injection: new_demo_sha256={sha256(expected)} bytes={len(expected)}")
        print("No workspace, build, component download or flash attempted")
        return 0

    work_root = args.work_root.resolve()
    dest = work_root / "full"
    if work_root == esp or esp in work_root.parents or work_root in esp.parents:
        raise ValueError("Work directory must be separate from PulseDeck source")
    if dest.exists() or dest.is_symlink():
        raise ValueError(f"Refusing to overwrite an existing test: {dest}")
    # Existing validated preparer creates an isolated copy and checks source JSON SHA.
    command = [sys.executable, str(preparer), "--mode", "full", "--esp-dir", str(esp),
               "--work-root", str(work_root)]
    print("Preparing original validated external-player project in isolated workspace", flush=True)
    subprocess.run(command, check=True)
    staged = dest / "main/espressif_player_demo.c"
    if not staged.is_file() or sha256(staged.read_bytes()) != DEMO_SHA:
        raise ValueError("Staged demo differs from validated source; do not build or flash")
    staged.write_bytes(expected)
    if sha256(staged.read_bytes()) != sha256(expected):
        raise ValueError("Staged half-speed source verification failed")
    print(f"READY: {dest}")
    print(f"Source override only in /tmp: {staged}")
    print(f"Source SHA256: {sha256(expected)}")
    print("Timing: frame_delay=33 ms, 360 frames, expected period 11880 ms (~12 s)")
    print("LVGL=9.5.0; Espressif player=0.1.0~1; ThorVG=0.15.16; stack UI=32 KiB")
    print("No build, component download, flash or baseline source modifications performed")
    print(f"From {dest}: idf.py build")
    print(f"From {dest}: idf.py -p /dev/ttyUSB0 flash")
    print(f"From {dest}: idf.py -p /dev/ttyUSB0 monitor")
    print("Observe at least 90 seconds, stop at first crash, report any visual issues")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, OSError, subprocess.CalledProcessError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        raise SystemExit(2)
