#pragma once
#include "esp_err.h"
#include "esp_lcd_panel_ops.h"
#include "lvgl.h"
esp_err_t pd_display_init(void);
lv_display_t *pd_display_get(void);
// Acces reserve aux essais RGB de bring-up.
esp_lcd_panel_handle_t pd_display_panel_get(void);

/* ESP-007: diagnostic framebuffer RGB */
void pd_display_framebuffer_snapshot(const char *stage);

/* ESP-013: returns the single RGB framebuffer, NULL if unavailable. */
uint16_t *pd_display_rgb_fb_get(void);

/* test_002-5-7: single UI-task flush profiling snapshot; reset counters. */
typedef struct {
    uint32_t count;
    uint64_t total_us;
    uint64_t rotate_us;
    uint64_t sync_us;
    uint32_t max_us;
    uint64_t pixels;
    uint32_t failures;
} pd_flush_profile_t;
void pd_display_flush_profile_take(pd_flush_profile_t *out);
