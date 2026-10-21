#include "display.h"
#include "esp_lcd_panel_ops.h"
#include "esp_lcd_panel_rgb.h"
#include "esp_lcd_st7701.h"
#include "esp_lcd_panel_io_additions.h"
#include "driver/gpio.h"
#include "esp_heap_caps.h"
#include "esp_cache.h"
#include "esp_log.h"
#include <stdint.h>
#include <string.h>
#include "esp_timer.h"
#include "esp_lcd_panel_rgb.h"

#define W 480
#define H 480
#define PIXEL_BYTES 2
#define PREFERRED_LINES 200
static unsigned actual_lines;
static unsigned failed_flushes;
static unsigned flush_count;
static const char *TAG = "pd_display";
static esp_lcd_panel_handle_t panel;
static lv_display_t *display;
static void *draw_buf;
static uint32_t sampled_fingerprint(const uint8_t *data, size_t len);
static const uint16_t *rgb_fb;
static bool framebuffer_accessible;
uint16_t *pd_display_rgb_fb_get(void) { return framebuffer_accessible ? (uint16_t *)rgb_fb : NULL; }
static uint32_t total_rows_ok, total_rows_bad;
static int64_t last_row_report_us;


static uint32_t fb_sample_digest(void)
{
    if (!framebuffer_accessible) return 0;
    const uint8_t *p = (const uint8_t *)rgb_fb;
    return sampled_fingerprint(p, (size_t)W * H * PIXEL_BYTES);
}

void pd_display_framebuffer_snapshot(const char *stage)
{
    if (!framebuffer_accessible) {
        ESP_LOGW(TAG, "FB SNAPSHOT %s: RGB framebuffer inaccessible", stage);
        return;
    }
    ESP_LOGI(TAG, "FB SNAPSHOT %s ptr=%p digest=0x%08lx corners=[%04x,%04x,%04x,%04x] mid=%04x", stage,
             (const void *)rgb_fb, (unsigned long)fb_sample_digest(),
             rgb_fb[0], rgb_fb[W-1], rgb_fb[(H-1)*W], rgb_fb[H*W-1], rgb_fb[(H/2)*W+W/2]);
}


static uint32_t sampled_fingerprint(const uint8_t *data, size_t len)
{
    // Empreinte des pixels transmis depuis LVGL; pas une lecture du framebuffer interne RGB.
    uint32_t h = 2166136261u;
    const size_t step = len > 8192 ? len / 4096 : 1;
    for (size_t i = 0; i < len; i += step) { h ^= data[i]; h *= 16777619u; }
    return h;
}
static void flush_cb(lv_display_t *disp, const lv_area_t *area, uint8_t *px_map)
{
    // ESP-017-1: rotate the actual LVGL RGB565 pixels 90 degrees clockwise.
    // LVGL logical coordinates stay 480x480. This is the ONLY rotation of LVGL;
    // do not also call lv_display_set_rotation() or esp_lcd_panel_swap_xy().
    const unsigned n = ++flush_count;
    const int x1 = area->x1, y1 = area->y1;
    const int width = area->x2 - x1 + 1;
    const int height = area->y2 - y1 + 1;
    if (!framebuffer_accessible || !rgb_fb) {
        if (++failed_flushes <= 8) ESP_LOGE(TAG, "ROT90 LVGL flush: framebuffer inaccessible");
        lv_display_flush_ready(disp);
        return;
    }
    uint16_t *dst = (uint16_t *)rgb_fb;
    const uint16_t *src = (const uint16_t *)px_map;
    // Source(x,y) -> screen(W-1-y,x); pixel data packed per LVGL partial area.
    for (int sy = 0; sy < height; ++sy) {
        for (int sx = 0; sx < width; ++sx) {
            const int x = x1 + sx, y = y1 + sy;
            dst[(size_t)x * W + (size_t)(W - 1 - y)] = src[(size_t)sy * width + sx];
        }
    }
    // RGB EDMA sees PSRAM framebuffer; flush CPU cache before completion.
    esp_err_t rc = esp_cache_msync(dst, (size_t)W * H * PIXEL_BYTES, ESP_CACHE_MSYNC_FLAG_DIR_C2M);
    if (rc != ESP_OK && ++failed_flushes <= 8)
        ESP_LOGE(TAG, "ROT90 LVGL cache sync failed: %s", esp_err_to_name(rc));
    if (n <= 20 || n % 250 == 0)
        ESP_LOGI(TAG, "ROT90 LVGL flush #%u area=(%d,%d)-(%ld,%ld) sync=%s", n,
                 x1, y1, (long)area->x2, (long)area->y2, esp_err_to_name(rc));
    lv_display_flush_ready(disp);
}

lv_display_t *pd_display_get(void) { return display; }
esp_lcd_panel_handle_t pd_display_panel_get(void) { return panel; }

/* Exact register values extracted from manufacturer Arduino_GFX-master/src/display/Arduino_ST7701_RGBPanel.h
 * st7701_type1_init_operations. Arduino bus batch format converted to Espressif command entries. */
static const st7701_lcd_init_cmd_t pd_st7701_mfr_init[] = {
    {0xFF, (const uint8_t[]){0x77, 0x01, 0x00, 0x00, 0x10}, 5, 0},
    {0xC0, (const uint8_t[]){0x3B, 0x00}, 2, 0},
    {0xC1, (const uint8_t[]){0x0D, 0x02}, 2, 0},
    {0xC2, (const uint8_t[]){0x31, 0x05}, 2, 0},
    {0xCD, (const uint8_t[]){0x00}, 1, 0},
    {0xB0, (const uint8_t[]){0x00, 0x11, 0x18, 0x0E, 0x11, 0x06, 0x07, 0x08, 0x07, 0x22, 0x04, 0x12, 0x0F, 0xAA, 0x31, 0x18}, 16, 0},
    {0xB1, (const uint8_t[]){0x00, 0x11, 0x19, 0x0E, 0x12, 0x07, 0x08, 0x08, 0x08, 0x22, 0x04, 0x11, 0x11, 0xA9, 0x32, 0x18}, 16, 0},
    {0xFF, (const uint8_t[]){0x77, 0x01, 0x00, 0x00, 0x11}, 5, 0},
    {0xB0, (const uint8_t[]){0x60}, 1, 0},
    {0xB1, (const uint8_t[]){0x32}, 1, 0},
    {0xB2, (const uint8_t[]){0x07}, 1, 0},
    {0xB3, (const uint8_t[]){0x80}, 1, 0},
    {0xB5, (const uint8_t[]){0x49}, 1, 0},
    {0xB7, (const uint8_t[]){0x85}, 1, 0},
    {0xB8, (const uint8_t[]){0x21}, 1, 0},
    {0xC1, (const uint8_t[]){0x78}, 1, 0},
    {0xC2, (const uint8_t[]){0x78}, 1, 0},
    {0xE0, (const uint8_t[]){0x00, 0x1B, 0x02}, 3, 0},
    {0xE1, (const uint8_t[]){0x08, 0xA0, 0x00, 0x00, 0x07, 0xA0, 0x00, 0x00, 0x00, 0x44, 0x44}, 11, 0},
    {0xE2, (const uint8_t[]){0x11, 0x11, 0x44, 0x44, 0xED, 0xA0, 0x00, 0x00, 0xEC, 0xA0, 0x00, 0x00}, 12, 0},
    {0xE3, (const uint8_t[]){0x00, 0x00, 0x11, 0x11}, 4, 0},
    {0xE4, (const uint8_t[]){0x44, 0x44}, 2, 0},
    {0xE5, (const uint8_t[]){0x0A, 0xE9, 0xD8, 0xA0, 0x0C, 0xEB, 0xD8, 0xA0, 0x0E, 0xED, 0xD8, 0xA0, 0x10, 0xEF, 0xD8, 0xA0}, 16, 0},
    {0xE6, (const uint8_t[]){0x00, 0x00, 0x11, 0x11}, 4, 0},
    {0xE7, (const uint8_t[]){0x44, 0x44}, 2, 0},
    {0xE8, (const uint8_t[]){0x09, 0xE8, 0xD8, 0xA0, 0x0B, 0xEA, 0xD8, 0xA0, 0x0D, 0xEC, 0xD8, 0xA0, 0x0F, 0xEE, 0xD8, 0xA0}, 16, 0},
    {0xEB, (const uint8_t[]){0x02, 0x00, 0xE4, 0xE4, 0x88, 0x00, 0x40}, 7, 0},
    {0xEC, (const uint8_t[]){0x3C, 0x00}, 2, 0},
    {0xED, (const uint8_t[]){0xAB, 0x89, 0x76, 0x54, 0x02, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x20, 0x45, 0x67, 0x98, 0xBA}, 16, 0},
    {0xFF, (const uint8_t[]){0x77, 0x01, 0x00, 0x00, 0x13}, 5, 0},
    {0xE5, (const uint8_t[]){0xE4}, 1, 0},
    {0xFF, (const uint8_t[]){0x77, 0x01, 0x00, 0x00, 0x00}, 5, 0},
    {0x3A, (const uint8_t[]){0x60}, 1, 10},
    {0x11, NULL, 0, 120},
    {0x29, NULL, 0, 0},
};

esp_err_t pd_display_init(void)
{
    // Brochage: reference constructeur ESP32-4848S040C_I.
    spi_line_config_t line = {
        .cs_io_type = IO_TYPE_GPIO, .cs_gpio_num = 39,
        .scl_io_type = IO_TYPE_GPIO, .scl_gpio_num = 48,
        .sda_io_type = IO_TYPE_GPIO, .sda_gpio_num = 47,
    };
    esp_lcd_panel_io_3wire_spi_config_t cfg = ST7701_PANEL_IO_3WIRE_SPI_CONFIG(line, 0);
    esp_lcd_panel_io_handle_t io = NULL;
    esp_err_t err = esp_lcd_new_panel_io_3wire_spi(&cfg, &io);
    if (err != ESP_OK) return err;

    esp_lcd_rgb_panel_config_t rgb = {
        .clk_src = LCD_CLK_SRC_DEFAULT,
        .timings = {
            .pclk_hz = 12000000,
            .h_res = W, .v_res = H,
            .hsync_pulse_width = 8, .hsync_back_porch = 50, .hsync_front_porch = 10,
            .vsync_pulse_width = 8, .vsync_back_porch = 20, .vsync_front_porch = 10,
            .flags.pclk_active_neg = 0,
        },
        .data_width = 16, .bits_per_pixel = 16,
        .num_fbs = 1,
        .bounce_buffer_size_px = W * 10, // two internal SRAM bounce buffers, each 10 lines
        .psram_trans_align = 64,
        .hsync_gpio_num = 16, .vsync_gpio_num = 17,
        .de_gpio_num = 18, .pclk_gpio_num = 21,
        .disp_gpio_num = GPIO_NUM_NC,
        // RGB565: B[0:4], G[0:5], R[0:4]
        .data_gpio_nums = {4, 5, 6, 7, 15, 8, 20, 3, 46, 9, 10, 11, 12, 13, 14, 0},
        .flags.fb_in_psram = 1,
    };
    ESP_LOGI(TAG, "RGB CONFIG pclk=%u neg=%u num_fbs=%u bounce_px=%u fb_psram=%u hsync_pulse=%u hback=%u hfront=%u vsync_pulse=%u vback=%u vfront=%u hsync_idle_low=%u vsync_idle_low=%u de_idle_high=%u color_order=RGB",
        (unsigned)rgb.timings.pclk_hz, (unsigned)rgb.timings.flags.pclk_active_neg,
        (unsigned)rgb.num_fbs, (unsigned)rgb.bounce_buffer_size_px, (unsigned)rgb.flags.fb_in_psram,
        (unsigned)rgb.timings.hsync_pulse_width, (unsigned)rgb.timings.hsync_back_porch, (unsigned)rgb.timings.hsync_front_porch,
        (unsigned)rgb.timings.vsync_pulse_width, (unsigned)rgb.timings.vsync_back_porch, (unsigned)rgb.timings.vsync_front_porch,
        (unsigned)rgb.timings.flags.hsync_idle_low, (unsigned)rgb.timings.flags.vsync_idle_low,
        (unsigned)rgb.timings.flags.de_idle_high);
    size_t internal_before_panel = heap_caps_get_free_size(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
    ESP_LOGI(TAG, "ST7701 init: manufacturer type1 table, %u entries", (unsigned)(sizeof(pd_st7701_mfr_init) / sizeof(pd_st7701_mfr_init[0])));
    st7701_vendor_config_t vendor = {
        .init_cmds = pd_st7701_mfr_init,
        .init_cmds_size = sizeof(pd_st7701_mfr_init) / sizeof(pd_st7701_mfr_init[0]),
        .rgb_config = &rgb,
        .flags.enable_io_multiplex = 0,
    };
    esp_lcd_panel_dev_config_t panel_cfg = {
        .reset_gpio_num = GPIO_NUM_NC,
        .rgb_ele_order = LCD_RGB_ELEMENT_ORDER_RGB,
        .bits_per_pixel = 16,
        .vendor_config = &vendor,
    };
    err = esp_lcd_new_panel_st7701(io, &panel_cfg, &panel);
    size_t internal_after_panel = heap_caps_get_free_size(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
    ESP_LOGI(TAG, "RGB PANEL internal_free_before=%u after=%u delta=%d (includes driver allocations)",
        (unsigned)internal_before_panel, (unsigned)internal_after_panel,
        (int)(internal_before_panel - internal_after_panel));
    if (err != ESP_OK) return err;
    err = esp_lcd_panel_reset(panel);
    if (err != ESP_OK) return err;
    // ST7701 returns the underlying RGB handle for non-multiplexed RGB mode.
    // Retrieve once; never interpret the RGB handle's internals directly.
    void *fb = NULL;
    esp_err_t fb_err = esp_lcd_rgb_panel_get_frame_buffer(panel, 1, &fb);
    framebuffer_accessible = (fb_err == ESP_OK && fb != NULL);
    rgb_fb = (const uint16_t *)fb;
    ESP_LOGI(TAG, "RGB framebuffer getter=%s ptr=%p enabled=%d", esp_err_to_name(fb_err), fb, framebuffer_accessible);
    err = esp_lcd_panel_init(panel);
    if (err != ESP_OK) return err;
    err = esp_lcd_panel_disp_on_off(panel, true);
    if (err != ESP_OK) return err;

    gpio_config_t backlight = {
        .pin_bit_mask = 1ULL << 38,
        .mode = GPIO_MODE_OUTPUT,
    };
    err = gpio_config(&backlight);
    if (err != ESP_OK) return err;

    display = lv_display_create(W, H);
    if (!display) return ESP_ERR_NO_MEM;
    // Manufacturer: INTERNAL | 8BIT, partial buffer 480x200 RGB565.
    // Leave room for system allocations: fall back to 80 then 40 lines, never silently use PSRAM.
    const unsigned options[] = {PREFERRED_LINES, 80, 40};
    size_t bytes = 0;
    for (unsigned i = 0; i < sizeof(options)/sizeof(options[0]); ++i) {
        bytes = W * options[i] * PIXEL_BYTES;
        draw_buf = heap_caps_malloc(bytes, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
        if (draw_buf) { actual_lines = options[i]; break; }
        ESP_LOGW(TAG, "Internal LVGL buffer of %u lines unavailable", options[i]);
    }
    if (!draw_buf) {
        ESP_LOGE(TAG, "No internal LVGL draw buffer available (40 lines minimum)");
        return ESP_ERR_NO_MEM;
    }
    lv_display_set_color_format(display, LV_COLOR_FORMAT_RGB565);
    lv_display_set_buffers(display, draw_buf, NULL, bytes, LV_DISPLAY_RENDER_MODE_PARTIAL);
    ESP_LOGI(TAG, "LVGL PARTIAL INTERNAL: lines=%u, bytes=%u, ptr=%p, free_internal=%u; RGB timing unchanged",
             actual_lines, (unsigned)bytes, draw_buf,
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT));
    lv_display_set_flush_cb(display, flush_cb);
    ESP_LOGI(TAG, "LVGL physical rotation=90 clockwise, handled in flush_cb; LVGL rotation API not used");
    gpio_set_level(GPIO_NUM_38, 1);
    ESP_LOGI(TAG, "ST7701 initialised 480x480, 12MHz pclk_active_neg=0; hardware validation pending");
    return ESP_OK;
}
