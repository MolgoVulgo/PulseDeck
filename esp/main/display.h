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
