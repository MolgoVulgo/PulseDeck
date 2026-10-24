#!/usr/bin/env python3
"""Prepare a standalone sdkconfig/build path for ONE PulseDeck Lottie profile.
Never flashes, builds, edits baseline files, or decides experiment order.
"""
import argparse, hashlib, re, shlex
from pathlib import Path

DEFAULT_WORK = Path("/tmp/pulsedeck_lottie_suite")

def set_kconfig(raw: str, key: str, value: str) -> str:
    pat = re.compile(rf"^(?:{re.escape(key)}=.*|# {re.escape(key)} is not set)$", re.M)
    updated, hits = pat.subn(f"{key}={value}", raw)
    if hits > 1:
        raise ValueError(f"duplicate sdkconfig entries for {key}")
    if hits == 0:
        updated = updated.rstrip("\n") + f"\n{key}={value}\n"
    return updated

def prepare(esp: Path, work: Path, profile: int, variant: str):
    original_path = esp / "sdkconfig"
    original = original_path.read_text(encoding="utf-8")
    assert "CONFIG_SPIRAM_USE_MALLOC=y" in original
    assert "CONFIG_LV_USE_LOTTIE=y" in original
    assert "CONFIG_ESP_INT_WDT_TIMEOUT_MS=300" in original
    # In all non-watchdog profiles, preserve 300 ms exactly.
    if profile == 3:
        original = set_kconfig(original, "CONFIG_ESP_INT_WDT_TIMEOUT_MS", "1000")
    if profile == 4:
        original = set_kconfig(original, "CONFIG_HEAP_USE_HOOKS", "y")
    name = f"profile_{profile}" + (f"_{variant}" if profile == 5 else "")
    dest = work / name
    dest.mkdir(parents=True, exist_ok=True)
    target = dest / "sdkconfig"
    target.write_text(original, encoding="utf-8")
    cmd = ["idf.py", "-B", str(dest / "build"), f"-DSDKCONFIG={target}",
           f"-DPD_LOTTIE_SUITE_TEST={profile}",
           "-DPD_LOTTIE_DIAG_ASSET=meteocons",
           "-DPD_LOTTIE_DIAG_FPS=5",
           f"-DPD_LOTTIE_SUITE_VARIANT={variant}", "build"]
    return name, target, cmd

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--profile", type=int, choices=(1,2,3,4,5), required=True)
    ap.add_argument("--variant", choices=("one", "two", "half", "full"), default="full")
    ap.add_argument("--work-dir", type=Path, default=DEFAULT_WORK)
    ap.add_argument("--esp-dir", type=Path, default=Path(__file__).resolve().parents[2])
    a = ap.parse_args()
    if a.profile != 5 and a.variant != "full": ap.error("variants apply only to profile 5")
    name, cfg, cmd = prepare(a.esp_dir.resolve(), a.work_dir.resolve(), a.profile, a.variant)
    print("Profile prepared (no compilation or flash performed):", name)
    print("Temp sdkconfig:", cfg, "sha256", hashlib.sha256(cfg.read_bytes()).hexdigest())
    print("Commands from ESP directory", a.esp_dir.resolve(), ":")
    print("  ", shlex.join(cmd))
    print("  ", shlex.join(["idf.py", "-B", str(a.work_dir.resolve()/name/"build"), "-p", "/dev/ttyUSB0", "flash"]))
    print("  ", shlex.join(["idf.py", "-B", str(a.work_dir.resolve()/name/"build"), "-p", "/dev/ttyUSB0", "monitor"]))
    print("Stop monitor at first panic; run each selected profile individually.")
    return 0
if __name__ == "__main__":
    raise SystemExit(main())
