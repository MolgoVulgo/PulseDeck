# Espressif Lottie player — PulseDeck weather icons

> Historical record: the temporary `esp/main/lottie_diag/` and `esp/main/lottie_assets/` test directories were removed during cleanup. Commands below describe the archived experiments and cannot run from the current checkout. Retrieve them from Git commit `91e7efc` when needed.

Status (2026-10-23): **selected reference engine**, **hardware-validated in an isolated ESP-IDF test**, **not yet integrated into the main PulseDeck firmware**. This document describes the tested configuration and the requirements for subsequent integration; it does not certify long-term operation.

French version: [`LOTTIE_ESPRESSIF.fr.md`](LOTTIE_ESPRESSIF.fr.md). Related hardware configuration: [`LCD_REFERENCE.md`](LCD_REFERENCE.md).

## 1. Decision and scope

- Use **Espressif `espressif/esp_lv_lottie_player`** for animated weather icons, with **external `espressif/thorvg`**. The native Lottie widget and built-in ThorVG from LVGL 9.5.0 must **not** be linked concurrently: both implementations export `lv_lottie_*` symbols.
- Preserve Meteocons' original Lottie JSON; no geometry removal or flattening is required for the validated `clear-day` icon.
- Use a **SquareLine Panel/Container** to reserve the icon area. Create the **`lv_lottie` widget in application code as its child** (or align it with a generated placeholder). `lv_lottie` itself derives from **`lv_canvas`**: an additional SquareLine Canvas is unnecessary. Do not edit `esp/components/ui/generated/` or the original SquareLine assets.
- This replaces the **chosen engine**, not automatically the main firmware's build files. The working player currently lives in an isolated `/tmp` test project.

## 2. Validated test configuration

| Setting | Isolated hardware-tested value |
| --- | --- |
| Board and display | ESP32-S3 / ESP32-4848S040C_I; 480 × 480 LCD |
| ESP-IDF / LVGL | v5.5 / 9.5.0 |
| Espressif player | `espressif/esp_lv_lottie_player ==0.1.0~1` |
| External ThorVG | `espressif/thorvg ==0.15.16` |
| UI task stack | **32,768 bytes** |
| Player's loading-worker stack | **32 KiB** (component implementation) |
| Source | `esp/ui/assets/meteocons/fill/clear-day.json` (original, **7,302 bytes**, SHA-256 `930084453639864f519a4e2d2b791b042ac94b67816614144ff28e471106fc24`) |
| Composition | 128 × 128; 360 frames, 60 FPS in source, two layers |
| Output / buffer | 64 × 64, ARGB8888, **16,384 bytes**, 64-byte-aligned PSRAM |
| JSON working copy | Writable PSRAM allocation; keep alive for the widget's lifetime |
| Native LVGL Lottie/ThorVG | Disabled in **isolated test configuration** |
| Interrupt watchdog | 300 ms, not disabled or extended |
| Default source-speed cycle | Approximately **6 seconds** (reference test `test_002-4-1`) |
| Tested half-speed cycle | `lv_lottie_set_frame_delay(obj, 33u)` → **360 × 33 ms = 11.88 seconds** (`test_002-4-2`) |

The isolated test also registered a separate 2 MiB LVGL pool in PSRAM. This is a **tested configuration detail**, not evidence that every future widget needs its own pool. The main-firmware memory layout must be reviewed before migration.

## 3. Component integration and isolation

The isolated test project used these version constraints in its component manifest:

```yaml
dependencies:
  lvgl/lvgl: "==9.5.0"
  espressif/esp_lv_lottie_player: "==0.1.0~1"
  espressif/thorvg: "==0.15.16"
```

It additionally resolved the project's ST7701, GT911 and LCD panel support components. These pins are a **known-good isolated combination**, not instructions to install dependencies without consent. Component Manager resolution and resulting lockfile were confined to `/tmp/pulsedeck_external_lottie/full` and `/tmp/pulsedeck_external_lottie_half_speed/full`; the main repository lockfile was not changed.

When integrating into the main build, **select exactly one Lottie/ThorVG implementation**. Disable native LVGL `LV_USE_LOTTIE` and its internal ThorVG/vector/SVG configuration **only after inspecting the final Kconfig/linker map** and accounting for any unrelated SVG users. The isolated preparator disabled these in a copied `sdkconfig` only. Verify that `lv_lottie_create` and related symbols resolve to `espressif__esp_lv_lottie_player` and that the external ThorVG is the linked renderer. Keep the original display driver, SquareLine-generated UI and PSRAM configuration unchanged unless a separate validated change is required.

Do not equate a successful isolated build with completed migration of the production firmware.

## 4. Creating an animated icon

Include `<esp_lv_lottie.h>`, `<esp_heap_caps.h>` and `<lvgl.h>`. The **tested sequence**, performed while LVGL access is properly serialized, is:

1. Allocate a **64 × 64 × 4 = 16,384-byte** PSRAM buffer aligned to 64 bytes. The test uses `heap_caps_aligned_alloc(64, 16384, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT)`.
2. Allocate a writable buffer of `json_len + 1` bytes in PSRAM, copy the **unmodified** JSON bytes and add a final `\0`. **Never pass flash-backed `const` JSON directly** to `lv_lottie_set_src_data`: Espressif's loader parses writable memory in place.
3. Create `lv_lottie_create(parent_container)`, set size/position, and call `lv_lottie_set_buffer(obj, pixel_buf, 64, 64)`.
4. Call `lv_lottie_set_src_data(obj, json_copy, json_len)` and check `lv_lottie_is_loaded(obj)` and `lv_lottie_get_total_frames(obj)` before playback.
5. Configure looping and optional playback speed, then call `lv_lottie_play(obj)`.
6. Keep **both allocations valid** for the lifetime of the widget; destroy the widget before releasing owned backing storage. Avoid repeated widget creation on each weather update; change the source through a controlled UI lifecycle.

Example — the variables `parent`, `pixels`, `json_copy` and `json_len` must have already been prepared as above:

```c
#include "lvgl.h"
#include "esp_lv_lottie.h"

lv_obj_t *obj = lv_lottie_create(parent);
lv_obj_set_size(obj, 64, 64);
lv_lottie_set_buffer(obj, pixels, 64, 64);
lv_lottie_set_src_data(obj, json_copy, json_len);
if (lv_lottie_is_loaded(obj)) {
    lv_lottie_set_loop_count(obj, -1);
    lv_lottie_set_loop_enabled(obj, true);
    lv_lottie_set_frame_delay(obj, 33u);  /* optional: ~50% speed */
    lv_lottie_play(obj);
}
```

For positioning with the current SquareLine screen, the isolated test created the widget as a **sibling** of `ui_test_Image1`, aligned to that placeholder and hid the placeholder only after a successful load. For new screens prefer a named container as the Lottie parent. All LVGL widget operations must run within the LVGL task/lock arrangement used by the firmware.

## 5. Playback timing

Espressif's `lv_lottie_set_frame_delay(obj, delay_ms)` overrides the source's frame duration and restarts the LVGL animation timeline when loaded. Apply it after `set_src_data` and **before** `lv_lottie_play` to avoid a perceptible restart.

| Delay | Approximate duration for 360 frames | Interpretation |
| --- | --- | --- |
| `0` | original, about 6 s | Use source timing; not zero-millisecond frames |
| `20` ms | 7.20 s | Slightly slower |
| `25` ms | 9.00 s | Moderate |
| **`33` ms** | **11.88 s** | **Half-speed baseline from `test_002-4-2`** |
| `40` ms | 14.40 s | Slower |

These are **animation timeline durations**, not guaranteed measured rendering FPS; actual draw rate depends on LVGL scheduling and load. A 33 ms delay yields ~30.3 logical frames per second. `33` ms is the validated half-speed **test setting**, pending final UI preference for other weather icons. Do not alter the Meteocons JSON to change speed.

## 6. Reproducing the isolated tests (Codex)

From the PulseDeck repository (with the ESP-IDF environment already available):

```sh
python3 esp/main/lottie_diag/prepare_espressif_player.py --mode full
# Creates /tmp/pulsedeck_external_lottie/full; no download, build or flash

python3 esp/main/lottie_diag/prepare_half_speed.py
# Creates /tmp/pulsedeck_external_lottie_half_speed/full; leaves the first workspace alone
```

Each prepared workspace contains its own copied sources and temporary `sdkconfig`. Inspect `idf_component.yml`, the selected port and the effective Kconfig before `idf.py build` / `flash` / `monitor`. Any dependency download requires explicit approval per the project policy. The preparators refuse to overwrite an existing workspace; do not clean/reset it implicitly.

Evidence is in Drive diagnostics **outside the source baseline**: `diagnostics/patch_test_002-4-1/report.md` (original-speed full JSON, 30–35 s, six wraps; user confirmed visually) and `diagnostics/patch_test_002-4-2/report.md` (33 ms delay, 40 s, three wraps; no panic). No post-load heap-integrity checks, multi-hour leak test or permanent integration has been validated. Test the main firmware separately after migration, including memory, UI responsiveness, orientation and source switching.

## 7. Compatibility references

- [Official component page](https://components.espressif.com/components/espressif/esp_lv_lottie_player/versions/0.1.0~1/readme)
- [Espressif player header (version used for analysis)](https://github.com/espressif/esp-iot-solution/blob/12f6ca1182ec48889b17ec570fadaaf267cb336e/components/display/tools/esp_lv_lottie_player/include/esp_lv_lottie.h)
- [Espressif player implementation](https://github.com/espressif/esp-iot-solution/blob/12f6ca1182ec48889b17ec570fadaaf267cb336e/components/display/tools/esp_lv_lottie_player/src/lv_lottie.c)
