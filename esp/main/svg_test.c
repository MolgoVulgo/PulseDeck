#include "svg_test.h"

#include <stdint.h>
#include "esp_log.h"
#include "esp_heap_caps.h"
#include "esp_timer.h"
#include "lvgl.h"
#include "ui.h"

/* test_002: LVGL 9.5 Lottie + ThorVG; reuse stable 2 MiB of explicit PSRAM
 * added to the LVGL built-in TLSF pool. SquareLine generated files and the
 * SquareLine generated UI and the original SVG assets remain unchanged. */
extern const uint8_t pd_lottie_clear_day_json[];
extern const uint32_t pd_lottie_clear_day_json_len;
extern const uint32_t pd_lottie_clear_day_fps_milli;
extern const uint32_t pd_lottie_clear_day_frames;

#define PD_LVGL_PSRAM_POOL_BYTES (2u * 1024u * 1024u)
#define PD_VECTOR_TEST_W 480u
#define PD_VECTOR_TEST_H 80u

static const char * TAG = "test_002";
static void * s_lvgl_psram_block;
static lv_mem_pool_t s_lvgl_psram_handle;

bool pd_svg_test_prepare_memory(void)
{
#if !LV_USE_SVG || !LV_USE_VECTOR_GRAPHIC || !LV_USE_THORVG
#error "test_001-2 requires LV_USE_SVG, VECTOR_GRAPHIC and THORVG"
#endif
#if LV_USE_STDLIB_MALLOC != LV_STDLIB_BUILTIN
#error "test_001-2 uses lv_mem_add_pool() with the LVGL built-in TLSF allocator"
#endif
    if (s_lvgl_psram_handle) return true;

    const size_t psram_before = heap_caps_get_free_size(MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    const size_t internal_before = heap_caps_get_free_size(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
    ESP_LOGI(TAG, "before pool: free_psram=%u B, free_internal=%u B, LVGL base=64 KiB",
             (unsigned)psram_before, (unsigned)internal_before);

    s_lvgl_psram_block = heap_caps_malloc(PD_LVGL_PSRAM_POOL_BYTES,
                                          MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (!s_lvgl_psram_block) {
        ESP_LOGE(TAG, "heap_caps_malloc 2 MiB PSRAM failed (largest_block=%u B)",
                 (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
        return false;
    }
    s_lvgl_psram_handle = lv_mem_add_pool(s_lvgl_psram_block, PD_LVGL_PSRAM_POOL_BYTES);
    if (!s_lvgl_psram_handle) {
        ESP_LOGE(TAG, "lv_mem_add_pool failed; verify CONFIG_LV_MEM_POOL_EXPAND_SIZE_KILOBYTES=2048");
        heap_caps_free(s_lvgl_psram_block);
        s_lvgl_psram_block = NULL;
        return false;
    }
    ESP_LOGI(TAG, "LVGL 2 MiB PSRAM TLSF pool registered: %p; free_psram=%u B",
             s_lvgl_psram_block,
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));

    /* Probe the exact large ARGB8888 intermediate buffer that the software
     * vector path needs on a 480x80 RGB565 partial screen band. 150 KiB is
     * larger than the built-in 64 KiB pool, so success proves a larger pool
     * is actually accessible to lv_draw_buf_create(). */
    int64_t t0_us = esp_timer_get_time();
    lv_draw_buf_t * probe = lv_draw_buf_create(PD_VECTOR_TEST_W, PD_VECTOR_TEST_H,
                                               LV_COLOR_FORMAT_ARGB8888, LV_STRIDE_AUTO);
    if (!probe) {
        ESP_LOGE(TAG, "ARGB8888 %ux%u probe allocation FAILED (LVGL pool exhausted)",
                 PD_VECTOR_TEST_W, PD_VECTOR_TEST_H);
        return false;
    }
    ESP_LOGI(TAG, "ARGB8888 %ux%u allocation OK: pixel_ptr=%p, bytes=%lu, stride=%lu",
             PD_VECTOR_TEST_W, PD_VECTOR_TEST_H, probe->data,
             (unsigned long)probe->data_size, (unsigned long)probe->header.stride);
    lv_draw_buf_clear(probe, NULL);
    lv_draw_buf_destroy(probe);
    ESP_LOGI(TAG, "ARGB8888 probe clear/destroy OK in %lld ms; free_psram=%u B, free_internal=%u B",
             (long long)((esp_timer_get_time() - t0_us) / 1000),
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT),
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT));
    return true;
}

#define PD_LOTTIE_W 64u
#define PD_LOTTIE_H 64u
#define PD_LOTTIE_BUFFER_BYTES (PD_LOTTIE_W * PD_LOTTIE_H * 4u)

static void *s_lottie_pixels;
static lv_obj_t *s_lottie_obj;

void pd_svg_test_start(void)
{
#if !LV_USE_LOTTIE || !LV_USE_CANVAS || !LV_USE_THORVG || !LV_USE_THORVG_INTERNAL
#error "test_002 requires LVGL9.5 Lottie, Canvas and ThorVG internal backend"
#endif
    if (!s_lvgl_psram_handle || !ui_test_Image1) {
        ESP_LOGE(TAG, "Lottie prerequisites absent: PSRAM pool or SquareLine Image1");
        return;
    }
    if (s_lottie_obj) return;
    if (pd_lottie_clear_day_json_len < 64 || pd_lottie_clear_day_fps_milli == 0) {
        ESP_LOGE(TAG, "Embedded Meteocons Lottie JSON invalid");
        return;
    }

    s_lottie_pixels = heap_caps_aligned_alloc(64, PD_LOTTIE_BUFFER_BYTES,
                                             MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (!s_lottie_pixels) {
        ESP_LOGE(TAG, "Lottie ARGB8888 buffer PSRAM allocation failed (%u bytes)",
                 (unsigned)PD_LOTTIE_BUFFER_BYTES);
        return;
    }

    lv_obj_set_size(ui_test_Image1, PD_LOTTIE_W, PD_LOTTIE_H);
    lv_obj_update_layout(ui_test_Image1);
    lv_obj_t *obj = lv_lottie_create(lv_obj_get_parent(ui_test_Image1));
    if (!obj) {
        ESP_LOGE(TAG, "lv_lottie_create failed");
        heap_caps_free(s_lottie_pixels);
        s_lottie_pixels = NULL;
        return;
    }
    lv_obj_set_size(obj, PD_LOTTIE_W, PD_LOTTIE_H);
    lv_obj_align_to(obj, ui_test_Image1, LV_ALIGN_CENTER, 0, 0);
    lv_lottie_set_buffer(obj, PD_LOTTIE_W, PD_LOTTIE_H, s_lottie_pixels);
    ESP_LOGI(TAG, "Load Lottie from flash: JSON bytes=%lu; frame count=%lu; source fps=%lu.%03lu",
             (unsigned long)pd_lottie_clear_day_json_len,
             (unsigned long)pd_lottie_clear_day_frames,
             (unsigned long)(pd_lottie_clear_day_fps_milli / 1000u),
             (unsigned long)(pd_lottie_clear_day_fps_milli % 1000u));
    lv_lottie_set_src_data(obj, pd_lottie_clear_day_json, pd_lottie_clear_day_json_len);
    lv_anim_t *anim = lv_lottie_get_anim(obj);
    if (!anim || anim->end_value <= 1) {
        ESP_LOGE(TAG, "ThorVG did not report multiple Lottie frames; stop test");
        lv_obj_delete(obj);
        heap_caps_free(s_lottie_pixels);
        s_lottie_pixels = NULL;
        return;
    }
    /* LVGL 9.5 lv_lottie hardcodes 60 FPS; adjust to Meteocons JSON's fr. */
    const uint32_t duration_ms = (uint32_t)((uint64_t)anim->end_value * 1000000u /
                                             pd_lottie_clear_day_fps_milli);
    lv_anim_set_duration(anim, duration_ms ? duration_ms : 1u);
    lv_anim_set_repeat_count(anim, LV_ANIM_REPEAT_INFINITE);
    lv_obj_add_flag(ui_test_Image1, LV_OBJ_FLAG_HIDDEN);
    s_lottie_obj = obj;
    ESP_LOGI(TAG, "Lottie running at Image1 center: %ux%u ARGB8888, frames=%ld, period=%lu ms, pixels=%p",
             (unsigned)PD_LOTTIE_W, (unsigned)PD_LOTTIE_H,
             (long)anim->end_value, (unsigned long)duration_ms, s_lottie_pixels);
}
