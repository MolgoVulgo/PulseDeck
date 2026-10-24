/* test_002-4 external: Espressif esp_lv_lottie_player 0.1.0~1.
 * Isolated /tmp ESP-IDF project only. Not used in PulseDeck's native build.
 * SquareLine assets and generated UI are NOT modified. */
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
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>

#if LV_USE_LOTTIE || LV_USE_THORVG_INTERNAL
#error "Native LVGL Lottie/ThorVG must be disabled in this isolated Espressif player build"
#endif
#if !LV_USE_CANVAS
#error "Espressif player requires LVGL Canvas"
#endif
#if LV_USE_STDLIB_MALLOC != LV_STDLIB_BUILTIN
#error "Explicit LVGL PSRAM pool requires built-in LVGL TLSF allocator"
#endif

extern const uint8_t pd_external_json_bytes[];
extern const size_t pd_external_json_len;
extern const char pd_external_asset_name[];

#define PD_POOL_BYTES (2u * 1024u * 1024u)
#define PD_ICON_W 64u
#define PD_ICON_H 64u

static const char *TAG = "PD_ESP_PLAYER";
static void *s_pool_mem;
static lv_mem_pool_t s_pool;
static lv_obj_t *s_player;
static uint8_t *s_json_copy;
static void *s_pixel_buf;
static int32_t s_last_frame = -1;
static uint32_t s_wraps;
static int64_t s_started_at_ms;

bool pd_svg_test_prepare_memory(void)
{
    if (s_pool) return true;
    ESP_LOGI(TAG, "ENGINE=espressif/esp_lv_lottie_player; native LVGL Lottie disabled");
    ESP_LOGI(TAG, "before pool internal=%lu psram=%lu",
             (unsigned long)heap_caps_get_free_size(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT),
             (unsigned long)heap_caps_get_free_size(MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
    s_pool_mem = heap_caps_malloc(PD_POOL_BYTES, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (!s_pool_mem) { ESP_LOGE(TAG, "PSRAM 2 MiB LVGL pool allocation failed"); return false; }
    s_pool = lv_mem_add_pool(s_pool_mem, PD_POOL_BYTES);
    if (!s_pool) { ESP_LOGE(TAG, "LVGL pool registration failed"); return false; }
    ESP_LOGI(TAG, "LVGL PSRAM pool=2 MiB registered; remaining_psram=%lu",
             (unsigned long)heap_caps_get_free_size(MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
    return true;
}

static void pd_player_heartbeat(lv_timer_t *timer)
{
    (void)timer;
    if (!s_player) return;
    int32_t frame = lv_lottie_get_current_frame(s_player);
    int32_t total = lv_lottie_get_total_frames(s_player);
    if (s_last_frame >= 0 && frame >= 0 && frame < s_last_frame) s_wraps++;
    s_last_frame = frame;
    ESP_LOGI(TAG, "HEARTBEAT elapsed_ms=%lld frame=%ld/%ld wraps=%lu loaded=%d",
             (long long)(esp_timer_get_time()/1000 - s_started_at_ms),
             (long)frame, (long)total, (unsigned long)s_wraps,
             (int)lv_lottie_is_loaded(s_player));
}

void pd_svg_test_start(void)
{
    if (!s_pool || !ui_test_Image1 || s_player) {
        ESP_LOGE(TAG, "invalid start: PSRAM pool, UI placeholder or duplicate");
        return;
    }
    ESP_LOGI(TAG, "ASSET=%s bytes=%lu; composition=128x128; output=64x64; source 60 FPS / 6 seconds",
             pd_external_asset_name, (unsigned long)pd_external_json_len);
    const uint32_t stride = lv_draw_buf_width_to_stride(PD_ICON_W, LV_COLOR_FORMAT_ARGB8888_PREMULTIPLIED);
    const size_t buffer_bytes = (size_t)stride * PD_ICON_H;
    if (stride != PD_ICON_W * 4u || buffer_bytes != 16384u) {
        ESP_LOGE(TAG, "unexpected LVGL ARGB8888 buffer stride=%lu", (unsigned long)stride);
        return;
    }
    s_pixel_buf = heap_caps_aligned_alloc(64, buffer_bytes, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (!s_pixel_buf) { ESP_LOGE(TAG, "PSRAM pixel allocation failed"); return; }
    /* The external API explicitly requires writable JSON retained across playback.
     * Never pass the flash-backed const source directly into the in-situ loader. */
    s_json_copy = heap_caps_malloc(pd_external_json_len + 1u, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (!s_json_copy) { ESP_LOGE(TAG, "PSRAM writable JSON allocation failed"); return; }
    memcpy(s_json_copy, pd_external_json_bytes, pd_external_json_len);
    s_json_copy[pd_external_json_len] = '\0';
    lv_obj_set_size(ui_test_Image1, PD_ICON_W, PD_ICON_H);
    lv_obj_update_layout(ui_test_Image1);

    int64_t t0 = esp_timer_get_time();
    ESP_LOGI(TAG, "ENTER lv_lottie_create");
    lv_obj_t *obj = lv_lottie_create(lv_obj_get_parent(ui_test_Image1));
    ESP_LOGI(TAG, "EXIT lv_lottie_create elapsed_ms=%lld", (long long)((esp_timer_get_time()-t0)/1000));
    if (!obj) { ESP_LOGE(TAG, "create failed"); return; }
    lv_obj_set_size(obj, PD_ICON_W, PD_ICON_H);
    lv_obj_align_to(obj, ui_test_Image1, LV_ALIGN_CENTER, 0, 0);
    t0 = esp_timer_get_time();
    ESP_LOGI(TAG, "ENTER external lv_lottie_set_buffer buf=%p bytes=%lu", s_pixel_buf, (unsigned long)buffer_bytes);
    lv_lottie_set_buffer(obj, s_pixel_buf, PD_ICON_W, PD_ICON_H);
    ESP_LOGI(TAG, "EXIT external lv_lottie_set_buffer elapsed_ms=%lld", (long long)((esp_timer_get_time()-t0)/1000));
    t0 = esp_timer_get_time();
    ESP_LOGI(TAG, "ENTER external lv_lottie_set_src_data writable=%p bytes=%lu",
             s_json_copy, (unsigned long)pd_external_json_len);
    lv_lottie_set_src_data(obj, s_json_copy, pd_external_json_len);
    ESP_LOGI(TAG, "EXIT external lv_lottie_set_src_data elapsed_ms=%lld", (long long)((esp_timer_get_time()-t0)/1000));
    if (!lv_lottie_is_loaded(obj)) { ESP_LOGE(TAG, "external source not loaded"); return; }
    ESP_LOGI(TAG, "loaded frames=%ld default_delay_ms=%lu",
             (long)lv_lottie_get_total_frames(obj),
             (unsigned long)lv_lottie_get_frame_delay(obj));
    lv_lottie_set_loop_count(obj, -1);
    lv_lottie_set_loop_enabled(obj, true);
    s_player = obj;
    lv_obj_add_flag(ui_test_Image1, LV_OBJ_FLAG_HIDDEN);
    s_started_at_ms = esp_timer_get_time()/1000;
    lv_timer_create(pd_player_heartbeat, 5000, NULL);
    ESP_LOGI(TAG, "ENTER lv_lottie_play");
    lv_lottie_play(obj);
    ESP_LOGI(TAG, "EXIT lv_lottie_play; RUNNING");
}
