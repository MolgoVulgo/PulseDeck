/* test_002-4-5: isolate rain alone, then load rain first with all 3 icons.
 * Standalone Espressif player build in /tmp only; SquareLine generated files are untouched.
 * Source bytes are embedded by prepare_three_icons.py in the temporary build workspace.
 */
#include "svg_test.h"
#include "sdkconfig.h"
#include "esp_log.h"
#include "esp_heap_caps.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "lvgl.h"
#include "esp_lv_lottie.h"
#include "ui.h"
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#if LV_USE_LOTTIE || LV_USE_THORVG_INTERNAL
#error "The native LVGL Lottie/ThorVG implementation must be disabled"
#endif
#if !LV_USE_CANVAS
#error "The Espressif player needs LVGL Canvas"
#endif
#if LV_USE_STDLIB_MALLOC != LV_STDLIB_BUILTIN
#error "The explicitly registered LVGL pool requires LVGL built-in TLSF"
#endif

#define PD_THREE_COUNT       3u
#define PD_ICON_W           64u
#define PD_ICON_H           64u
#define PD_POOL_BYTES       (2u * 1024u * 1024u)
#define PD_HEARTBEAT_MS     5000u
/* Build-local test selector: 1=rain_only, 2=rain_first, 0=full (control).
 * Only this diagnostic module changes; always maintain the real UI mapping.
 */
#ifndef PD_THREE_TEST_VARIANT
#define PD_THREE_TEST_VARIANT 1
#endif
#if PD_THREE_TEST_VARIANT < 0 || PD_THREE_TEST_VARIANT > 2
#error "Unexpected diagnostic case"
#endif

extern const uint8_t pd_three_clear_day_json[];
extern const size_t pd_three_clear_day_len;
extern const uint32_t pd_three_clear_day_frames;
extern const uint32_t pd_three_clear_day_fps_milli;
extern const uint8_t pd_three_fog_json[];
extern const size_t pd_three_fog_len;
extern const uint32_t pd_three_fog_frames;
extern const uint32_t pd_three_fog_fps_milli;
extern const uint8_t pd_three_rain_json[];
extern const size_t pd_three_rain_len;
extern const uint32_t pd_three_rain_frames;
extern const uint32_t pd_three_rain_fps_milli;

typedef struct {
    const char *name;
    const uint8_t *json;
    size_t json_len;
    uint32_t frames;
    uint32_t fps_milli;
} pd_asset_t;

typedef struct {
    lv_obj_t *obj;
    uint8_t *json_copy;
    void *pixel_buf;
    int32_t last_frame;
    uint32_t wraps;
} pd_icon_t;

static const char *TAG = "PD_THREE_ICONS";
static void *s_lvgl_pool_memory;
static lv_mem_pool_t s_lvgl_pool;
static pd_icon_t s_icons[PD_THREE_COUNT];
static bool s_started;
static int64_t s_start_ms;

bool pd_svg_test_prepare_memory(void)
{
    if (s_lvgl_pool) return true;
    ESP_LOGI(TAG, "ENGINE=espressif/esp_lv_lottie_player; 3 independent original JSON files");
    ESP_LOGI(TAG, "pre_pool internal=%lu psram=%lu",
             (unsigned long)heap_caps_get_free_size(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT),
             (unsigned long)heap_caps_get_free_size(MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
    s_lvgl_pool_memory = heap_caps_malloc(PD_POOL_BYTES, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (!s_lvgl_pool_memory) {
        ESP_LOGE(TAG, "FAIL LVGL 2 MiB PSRAM pool allocation");
        return false;
    }
    s_lvgl_pool = lv_mem_add_pool(s_lvgl_pool_memory, PD_POOL_BYTES);
    if (!s_lvgl_pool) {
        ESP_LOGE(TAG, "FAIL LVGL PSRAM pool registration");
        return false;
    }
    ESP_LOGI(TAG, "PSRAM pool=2097152 bytes registered");
    return true;
}

static bool pd_create_icon(size_t index, lv_obj_t *parent, const pd_asset_t *asset)
{
    pd_icon_t *slot = &s_icons[index];
    const uint32_t stride = lv_draw_buf_width_to_stride(PD_ICON_W, LV_COLOR_FORMAT_ARGB8888_PREMULTIPLIED);
    const size_t pixel_bytes = (size_t)stride * PD_ICON_H;
    if (stride != (PD_ICON_W * 4u) || pixel_bytes != 16384u) {
        ESP_LOGE(TAG, "FAIL %s: unexpected ARGB8888 stride=%lu", asset->name, (unsigned long)stride);
        return false;
    }
    /* SquareLine's exported symbol spelling is case-sensitive; do not infer
     * object size from pre-layout coordinates. The screen layout is updated
     * before this function is called by pd_svg_test_start(). */
    if (!parent) {
        ESP_LOGE(TAG, "FAIL %s: NULL SquareLine parent for Container%lu",
                 asset->name, (unsigned long)(index + 1u));
        return false;
    }
    const int32_t actual_w = lv_obj_get_width(parent);
    const int32_t actual_h = lv_obj_get_height(parent);
    lv_obj_t *actual_screen = lv_obj_get_parent(parent);
    ESP_LOGI(TAG, "CONTAINER_CHECK index=%lu parent=%p screen_parent=%p expected_screen=%p size=%ldx%ld expected=64x64",
             (unsigned long)(index + 1u), (void *)parent,
             (void *)actual_screen, (void *)ui_test, (long)actual_w, (long)actual_h);
    if (actual_screen != ui_test || actual_w != PD_ICON_W || actual_h != PD_ICON_H) {
        ESP_LOGE(TAG, "FAIL %s: Container%lu parent/screen/dimensions mismatch (size=%ldx%ld)",
                 asset->name, (unsigned long)(index + 1u),
                 (long)actual_w, (long)actual_h);
        return false;
    }
    slot->last_frame = -1;
    slot->pixel_buf = heap_caps_aligned_alloc(64, pixel_bytes, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    slot->json_copy = heap_caps_malloc(asset->json_len + 1u, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (!slot->pixel_buf || !slot->json_copy) {
        ESP_LOGE(TAG, "FAIL %s: PSRAM allocation (pixel=%p json=%p)", asset->name,
                 slot->pixel_buf, slot->json_copy);
        return false;
    }
    memcpy(slot->json_copy, asset->json, asset->json_len);
    slot->json_copy[asset->json_len] = '\0';

    int64_t t0 = esp_timer_get_time();
    slot->obj = lv_lottie_create(parent);  /* Espressif widget extends lv_canvas. */
    if (!slot->obj) {
        ESP_LOGE(TAG, "FAIL %s: lv_lottie_create", asset->name);
        return false;
    }
    lv_obj_set_size(slot->obj, PD_ICON_W, PD_ICON_H);
    lv_obj_center(slot->obj);
    lv_lottie_set_buffer(slot->obj, slot->pixel_buf, PD_ICON_W, PD_ICON_H);
    ESP_LOGI(TAG, "LOAD_BEGIN index=%lu name=%s bytes=%lu", (unsigned long)(index + 1u),
             asset->name, (unsigned long)asset->json_len);
    lv_lottie_set_src_data(slot->obj, slot->json_copy, asset->json_len);
    if (!lv_lottie_is_loaded(slot->obj)) {
        ESP_LOGE(TAG, "FAIL %s: Lottie loader returned unloaded", asset->name);
        return false;
    }
    const int32_t actual_frames = lv_lottie_get_total_frames(slot->obj);
    if (actual_frames < 1 || (uint32_t)actual_frames != asset->frames) {
        ESP_LOGE(TAG, "FAIL %s: frame count=%ld expected=%lu", asset->name,
                 (long)actual_frames, (unsigned long)asset->frames);
        return false;
    }
    /* 2x source frame duration = 50% playback speed. 60 FPS -> 33 ms/frame. */
    const uint32_t frame_delay_ms = (uint32_t)((2000000ull + asset->fps_milli / 2u) / asset->fps_milli);
    lv_lottie_set_loop_count(slot->obj, -1);
    lv_lottie_set_loop_enabled(slot->obj, true);
    lv_lottie_set_frame_delay(slot->obj, frame_delay_ms);
    ESP_LOGI(TAG, "LOAD_OK index=%lu name=%s ms=%lld frames=%ld source_fps_milli=%lu delay_ms=%lu expected_loop_ms=%lu",
             (unsigned long)(index + 1u), asset->name,
             (long long)((esp_timer_get_time() - t0) / 1000), (long)actual_frames,
             (unsigned long)asset->fps_milli, (unsigned long)frame_delay_ms,
             (unsigned long)(asset->frames * frame_delay_ms));
    return true;
}

static void pd_three_heartbeat(lv_timer_t *timer)
{
    (void)timer;
    for (size_t i = 0; i < PD_THREE_COUNT; i++) {
        pd_icon_t *p = &s_icons[i];
        if (!p->obj) continue;
        const int32_t frame = lv_lottie_get_current_frame(p->obj);
        const int32_t total = lv_lottie_get_total_frames(p->obj);
        if (p->last_frame >= 0 && frame >= 0 && frame < p->last_frame) p->wraps++;
        p->last_frame = frame;
        ESP_LOGI(TAG, "HEARTBEAT elapsed_ms=%lld index=%lu frame=%ld/%ld wraps=%lu loaded=%d",
                 (long long)(esp_timer_get_time() / 1000 - s_start_ms),
                 (unsigned long)(i + 1u), (long)frame, (long)total,
                 (unsigned long)p->wraps, (int)lv_lottie_is_loaded(p->obj));
    }
}

void pd_svg_test_start(void)
{
    if (s_started || !s_lvgl_pool || !ui_test) {
        ESP_LOGE(TAG, "FAIL invalid start (ui_test/pool/duplicate)");
        return;
    }
    /* Force LVGL layout evaluation before checking width/height: object
     * coords may be stale until the first lv_timer_handler. */
    lv_obj_update_layout(ui_test);
    lv_obj_t *containers[PD_THREE_COUNT] = {
        ui_test_Container1, ui_test_Container2, ui_test_Container3
    };
    const pd_asset_t assets[PD_THREE_COUNT] = {
        {"clear-day", pd_three_clear_day_json, pd_three_clear_day_len,
         pd_three_clear_day_frames, pd_three_clear_day_fps_milli},
        {"fog", pd_three_fog_json, pd_three_fog_len,
         pd_three_fog_frames, pd_three_fog_fps_milli},
        {"rain", pd_three_rain_json, pd_three_rain_len,
         pd_three_rain_frames, pd_three_rain_fps_milli}
    };
    /* load_order indexes logical slots, never remaps assets between containers:
     * Container1=clear-day, Container2=fog, Container3=rain in ALL cases. */
#if PD_THREE_TEST_VARIANT == 1
    const size_t load_order[] = { 2u };         /* rain in Container3 only */
    const char *case_name = "rain_only";
#elif PD_THREE_TEST_VARIANT == 2
    const size_t load_order[] = { 2u, 0u, 1u }; /* rain first; all three */
    const char *case_name = "rain_first";
#else
    const size_t load_order[] = { 0u, 1u, 2u }; /* prior failing order */
    const char *case_name = "full";
#endif
    const size_t active_count = sizeof(load_order) / sizeof(load_order[0]);
    ESP_LOGI(TAG, "CASE=%s BEGIN active=%lu UI mapping: C1=clear-day C2=fog C3=rain; half speed",
             case_name, (unsigned long)active_count);
    for (size_t j = 0; j < active_count; j++) {
        const size_t i = load_order[j];
        ESP_LOGI(TAG, "LOAD_ORDER case=%s ordinal=%lu container=%lu asset=%s",
                 case_name, (unsigned long)(j + 1u), (unsigned long)(i + 1u), assets[i].name);
        if (!pd_create_icon(i, containers[i], &assets[i])) {
            ESP_LOGE(TAG, "FAIL case=%s at container=%lu; stop test",
                     case_name, (unsigned long)(i + 1u));
            return;
        }
    }
    s_start_ms = esp_timer_get_time() / 1000;
    lv_timer_create(pd_three_heartbeat, PD_HEARTBEAT_MS, NULL);
    for (size_t j = 0; j < active_count; j++) lv_lottie_play(s_icons[load_order[j]].obj);
    s_started = true;
    ESP_LOGI(TAG, "RUNNING case=%s widgets=%lu PSRAM_pixel_bytes=%lu UI_stack=32768 delay=33ms",
             case_name, (unsigned long)active_count, (unsigned long)(active_count * 16384u));
}
