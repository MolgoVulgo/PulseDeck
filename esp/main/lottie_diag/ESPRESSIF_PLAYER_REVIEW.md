# test_002-4 / profile 7 — external Espressif player comparator (gated)

**Status:** REVIEW / PREFLIGHT ONLY. Not a buildable or flashable alternative in this ZIP.

Official component: `espressif/esp_lv_lottie_player` version `0.1.0~1`, separate dependency `espressif/thorvg` 0.15.x and LVGL v8/v9. See https://components.espressif.com/components/espressif/esp_lv_lottie_player/versions/0.1.0~1/readme . The official component example supports ESP32-S3 (https://components.espressif.com/components/espressif/esp_lv_lottie_player/versions/0.1.0~1/examples/lvgl_lottie_player).

Crucial **symbol collision**: the native `lv_lottie_*` implementation in LVGL 9.5 and the Espressif player expose same-named functions. The latter also brings a ThorVG component; its linkage and loader must be audited against built-in ThorVG. It must NOT be linked into the existing PulseDeck firmware alongside the native widget.

A future separately-authorized comparison must use a new isolated ESP-IDF application/project, and explicitly choose one Lottie implementation/ThorVG version, rather than changing PulseDeck's lockfile. No automatic `idf.py add-dependency`, package-manager network access, installing components, hardware flashing, or editing LVGL is authorized by this patch.

Minimum evidence before comparing: ESP-IDF 5.5 compatibility, resolved dependency and symbol map, 32-KiB LVGL/task worker stacks as required, explicit PSRAM ARGB8888 buffer, source JSON SHA256 `930084453639864f519a4e2d2b791b042ac94b67816614144ff28e471106fc24` and size 7302 bytes, playback over 160 seconds, two decoded CPU traces on errors, visual fidelity. Distinguish CPU/frame performance from native test profiles 1-6.

`python3 esp/main/lottie_diag/prepare_diagnostic.py --mode espressif_player` performs only this disclosure, and creates no build directories.
