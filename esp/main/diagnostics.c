#include "diagnostics.h"
#include "lvgl.h"
#include "esp_timer.h"
#include "esp_heap_caps.h"
#include <inttypes.h>

static lv_obj_t *stats;
static void update_stats(lv_timer_t *timer)
{
    (void)timer;
    uint64_t sec = (uint64_t)esp_timer_get_time() / 1000000ULL;
    unsigned long heap_kib = (unsigned long)(heap_caps_get_free_size(MALLOC_CAP_INTERNAL) / 1024U);
    unsigned long psram_kib = (unsigned long)(heap_caps_get_free_size(MALLOC_CAP_SPIRAM) / 1024U);
    lv_label_set_text_fmt(stats, "Uptime: %" PRIu64 " s\nHeap interne: %lu KiB\nPSRAM libre: %lu KiB\nWi-Fi: non initialise\nMQTT: hors phase 0",
                          sec, heap_kib, psram_kib);
}
void pd_diagnostics_create(void)
{
    lv_obj_t *screen = lv_screen_active();
    lv_obj_set_style_bg_color(screen, lv_color_hex(0x101820), 0);
    lv_obj_t *title = lv_label_create(screen);
    lv_label_set_text(title, "PulseDeck | Diagnostic local");
    lv_obj_set_style_text_color(title, lv_color_white(), 0);
    lv_obj_align(title, LV_ALIGN_TOP_MID, 0, 32);
    stats = lv_label_create(screen);
    lv_obj_set_style_text_color(stats, lv_color_white(), 0);
    lv_obj_align(stats, LV_ALIGN_TOP_LEFT, 24, 100);
    update_stats(NULL);
    lv_timer_create(update_stats, 1000, NULL);
}
