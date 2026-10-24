#!/usr/bin/env python3
"""Prepare a standalone ESP-IDF test workspace; NEVER touch PulseDeck baseline.

No network access, installation, build or flash is performed by this script.
Codex must request explicit permission if a build needs to fetch components.
"""
from __future__ import annotations
import argparse
import hashlib
import importlib.util
from pathlib import Path
import shutil
import sys

SHA_ORIGINAL = "930084453639864f519a4e2d2b791b042ac94b67816614144ff28e471106fc24"
SHA_REDUCED = "c1e0ce70a19787ea052fb5c61cba4a434f692424822c87f38b73ca8c4dc0f9b1"
MAIN_SOURCES = (
    "main.c", "display.c", "display.h", "touch.c", "touch.h",
    "lvgl_port.c", "lvgl_port.h", "svg_test.h",
)
COMPONENT_YAML = '''dependencies:
  lvgl/lvgl: "==9.5.0"
  espressif/esp_lcd_st7701: "==1.1.2"
  espressif/esp_lcd_panel_io_additions: "^1.0.0"
  espressif/esp_lcd_touch_gt911: "^1.2.0"
  espressif/esp_lv_lottie_player: "==0.1.0~1"
  espressif/thorvg: "==0.15.16"
'''
MAIN_CMAKE = '''# Standalone Espressif Lottie player diagnostic; isolated copy only.
idf_component_register(
    SRCS "main.c" "display.c" "touch.c" "lvgl_port.c"
         "espressif_player_demo.c" "pd_external_json.c"
    INCLUDE_DIRS "."
    REQUIRES esp_timer esp_system esp_lcd esp_driver_gpio esp_driver_i2c
             esp_psram esp_mm espressif__esp_lv_lottie_player
    PRIV_REQUIRES ui esp_rom esp_wifi esp_driver_tsens
)
target_compile_definitions(${COMPONENT_LIB} PRIVATE
    PD_UI_TASK_STACK_BYTES=32768 PD_DIAG_NO_HEAP_POLL=1)
message(STATUS "PulseDeck external player: ESPRESSIF engine, UI stack=32768, native Lottie OFF")
'''
# Keep all other baseline settings, including PSRAM/touch/display/watchdogs.
DISABLE_FLAGS = (
    "LV_USE_LOTTIE", "LV_USE_THORVG", "LV_USE_THORVG_INTERNAL",
    "LV_USE_VECTOR_GRAPHIC", "LV_USE_SVG", "LV_USE_SVG_ANIMATION",
)

def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()

def require_file(path: Path) -> Path:
    if not path.is_file() or path.is_symlink():
        raise ValueError(f"Missing or unsafe source file: {path}")
    return path

def write_config(src: Path, dst: Path):
    rows = require_file(src).read_text().splitlines()
    for key in DISABLE_FLAGS:
        rows = [row for row in rows if row != f"CONFIG_{key}=y" and row != f"CONFIG_{key}=n"
                and row != f"# CONFIG_{key} is not set"]
        rows.append(f"# CONFIG_{key} is not set")
    dst.write_text("\n".join(rows) + "\n")

def copy_tree_without_links(src: Path, dst: Path):
    # A copied SquareLine-generated source tree; no modifications to originals.
    for p in src.rglob("*"):
        if p.is_symlink():
            raise ValueError(f"Symlink in UI component: {p}")
    shutil.copytree(src, dst, symlinks=False)

def json_for_mode(esp: Path, mode: str):
    raw = require_file(esp / "ui/assets/meteocons/fill/clear-day.json").read_bytes()
    if sha(raw) != SHA_ORIGINAL:
        raise ValueError(f"Meteocons clear-day.json SHA mismatch: {sha(raw)}")
    if mode == "full":
        return raw
    generator_path = require_file(esp / "main/lottie_diag/generate_layer_tests.py")
    spec = importlib.util.spec_from_file_location("pd_layers_test", generator_path)
    if not spec or not spec.loader:
        raise ValueError("Cannot load previously validated layer generator")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    variants, _, _ = module.create(raw)
    reduced = variants["b_reduced"]
    if sha(reduced) != SHA_REDUCED:
        raise ValueError(f"Expected exact 847-byte B-reduced diagnostic, got {sha(reduced)}")
    return reduced

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--mode", choices=("full", "b_reduced"), default="full")
    p.add_argument("--esp-dir", type=Path, default=Path(__file__).resolve().parents[2])
    p.add_argument("--work-root", type=Path, default=Path("/tmp/pulsedeck_external_lottie"))
    args = p.parse_args()
    esp = args.esp_dir.resolve(strict=True)
    dst = args.work_root.resolve() / args.mode
    if dst.exists():
        raise ValueError(f"Refusing to overwrite existing test workspace: {dst}")
    if dst == esp or esp in dst.parents or dst in esp.parents:
        raise ValueError("Work directory must be wholly separate from the PulseDeck source")
    for marker in ("CMakeLists.txt", "sdkconfig", "sdkconfig.defaults", "idf_component.yml"):
        require_file(esp / marker)
    require_file(esp / "components/ui/CMakeLists.txt")
    data = json_for_mode(esp, args.mode)
    demo = require_file(esp / "main/lottie_diag/espressif_player_demo.c")
    for name in MAIN_SOURCES:
        require_file(esp / "main" / name)
    # Validate before creating the workspace.
    ui_src = esp / "components/ui"
    for source in ui_src.rglob("*"):
        if source.is_symlink():
            raise ValueError(f"Symlink not supported: {source}")
    dst.mkdir(parents=True)
    try:
        shutil.copy2(esp / "CMakeLists.txt", dst / "CMakeLists.txt")
        shutil.copy2(esp / "idf_component.yml", dst / "idf_component.yml")
        write_config(esp / "sdkconfig", dst / "sdkconfig")
        write_config(esp / "sdkconfig.defaults", dst / "sdkconfig.defaults")
        copy_tree_without_links(ui_src, dst / "components/ui")
        main_dir = dst / "main"
        main_dir.mkdir()
        for name in MAIN_SOURCES:
            shutil.copy2(esp / "main" / name, main_dir / name)
        shutil.copy2(demo, main_dir / "espressif_player_demo.c")
        (main_dir / "CMakeLists.txt").write_text(MAIN_CMAKE)
        (main_dir / "idf_component.yml").write_text(COMPONENT_YAML)
        rows = ["/* Exact, SHA-checked Lottie JSON embedded into test firmware. */",
                "#include <stddef.h>", "#include <stdint.h>",
                "const uint8_t pd_external_json_bytes[] = {"]
        payload = data + b"\0"
        for i in range(0, len(payload), 20):
            rows.append("    " + ", ".join(f"0x{x:02x}" for x in payload[i:i+20]) + ",")
        rows.extend(["};", f"const size_t pd_external_json_len = {len(data)}u;",
                     f'const char pd_external_asset_name[] = "{args.mode}";', ""])
        (main_dir / "pd_external_json.c").write_text("\n".join(rows))
    except Exception:
        shutil.rmtree(dst)
        raise
    print(f"Isolated ESP-IDF project: {dst}")
    print(f"ASSET mode={args.mode} bytes={len(data)} sha256={sha(data)}")
    print("LVGL=9.5.0, Espressif Lottie=0.1.0~1, external ThorVG=0.15.16")
    print("Native LVGL Lottie/ThorVG/SVG disabled ONLY in staged sdkconfig")
    print("UI stack=32768; external loader worker=32768; frame duration=original JSON")
    print("NO dependencies installed, NO build performed, NO hardware flashed")
    print(f"After explicit dependency-install permission: cd {dst} && idf.py build")
    print(f"Then: cd {dst} && idf.py -p /dev/ttyUSB0 flash")
    print(f"Then: cd {dst} && idf.py -p /dev/ttyUSB0 monitor")
    print("Stop on first crash. Otherwise collect 160 s + physical visual check.")

if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"FAIL: {e}", file=sys.stderr)
        sys.exit(2)
