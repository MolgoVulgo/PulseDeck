#include "rgb_test.h"
#include "display.h"
#include "esp_lcd_panel_ops.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include <stdint.h>
#include <stdlib.h>
#include <stddef.h>
#include "esp_timer.h"
#include "esp_cache.h"

#define RGB_WIDTH 480
#define RGB_HEIGHT 480
#define RGB_STRIP_LINES 20
#define RGB_STRIP_PIXELS (RGB_WIDTH * RGB_STRIP_LINES)
static const char *TAG = "pd_rgb_test";

static esp_err_t fill_color(esp_lcd_panel_handle_t panel, uint16_t color)
{
    // Bande de 20 lignes: consommation faible de memoire interne.
    uint16_t *pixels = heap_caps_malloc(RGB_STRIP_PIXELS * sizeof(uint16_t), MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
    if (!pixels) return ESP_ERR_NO_MEM;
    for (size_t i = 0; i < RGB_STRIP_PIXELS; ++i) pixels[i] = color;
    esp_err_t err = ESP_OK;
    for (int y = 0; y < RGB_HEIGHT; y += RGB_STRIP_LINES) {
        err = esp_lcd_panel_draw_bitmap(panel, 0, y, RGB_WIDTH, y + RGB_STRIP_LINES, pixels);
        if (err != ESP_OK) break;
    }
    free(pixels);
    return err;
}

static uint16_t pattern_pixel(int x, int y)
{
    // Grille + diagonales + quadrants, non uniforme pour verifier l'adressage.
    if ((x % 40) < 2 || (y % 40) < 2) return 0xffff;
    if (x == y || x == RGB_WIDTH - 1 - y) return 0x0000;
    if (x < 240 && y < 240) return 0xf800;
    if (x >= 240 && y < 240) return 0x07e0;
    if (x < 240) return 0x001f;
    return 0xffe0;
}
static uint16_t gray565(int level)
{
    unsigned c = (unsigned)level;
    return (uint16_t)(((c >> 3) << 11) | ((c >> 2) << 5) | (c >> 3));
}

static uint16_t test_pattern_pixel(unsigned pattern, int x, int y)
{
    static const uint16_t colors[8] = {0xf800,0x07e0,0x001f,0xffe0,0x07ff,0xf81f,0xffff,0x0000};
    switch (pattern) {
    case 1: return (x & 1) ? 0xffff : 0x0000;
    case 2: return (y & 1) ? 0xffff : 0x0000;
    case 3: return ((x / 8) & 1) ? 0xffff : 0x0000;
    case 4: return gray565(x * 255 / (RGB_WIDTH - 1));
    case 5: return gray565(y * 255 / (RGB_HEIGHT - 1));
    case 6: return colors[y % 8];
    case 7: return pattern_pixel(x, y);
    case 12:
    case 13:
        // Rotation logicielle des seules mires de reference, 90 deg horaire.
        // Ecran carre: (x,y) -> (y,479-x) pour relire la mire de base.
        return test_pattern_pixel(pattern - 2, y, RGB_WIDTH - 1 - x);
    case 14: return 0x0000; // effacement noir / persistance
    case 15: return 0xffff; // effacement blanc / persistance
    case 16: return test_pattern_pixel(12, x, y); // relance reference tournee
    case 17: return 0x0000; // effacement noir long
    case 10:
    case 11: {
        // Repères asymétriques en coordonnées FRAMEBUFFER, sans rotation.
        // P10: 4 coins uniques + axe X en haut + axe Y a gauche.
        // P11: meme carte mais fond alterne (controle de dependance couleur).
        const uint16_t bg = pattern == 10 ? 0x0000 : 0xffff;
        const uint16_t fg = pattern == 10 ? 0xffff : 0x0000;
        if (x < 90 && y < 90) return 0xf800; // haut-gauche rouge
        if (x >= 390 && y < 90) return 0x07e0; // haut-droit vert
        if (x < 90 && y >= 390) return 0x001f; // bas-gauche bleu
        if (x >= 390 && y >= 390) return 0xffe0; // bas-droit jaune
        // Marques axe X : barres verticales sur 20 px du bord SUPERIEUR.
        if (y < 20 && x >= 100 && x < 380) return ((x / 20) & 1) ? fg : bg;
        // Marques axe Y : barres horizontales sur 20 px du bord GAUCHE.
        if (x < 20 && y >= 100 && y < 380) return ((y / 20) & 1) ? fg : bg;
        // Croisillon central plus espace noir/blanc, volontairement asymetrique.
        if (x >= 220 && x < 260 && y >= 150 && y < 330) return 0x07ff;
        if (y >= 220 && y < 260 && x >= 150 && x < 330) return 0xf81f;
        return bg;
    }
    case 8:
    case 9: {
        // Twelve horizontal 40-pixel bands: known, fixed framebuffer y ranges.
        // Two-pixel black delimiters permit a precise physical y observation.
        static const uint16_t bars[12] = {
            0xf800, 0x07e0, 0x001f, 0xffe0, 0x07ff, 0xf81f,
            0xffff, 0x8410, 0xf800, 0x07e0, 0x001f, 0xffff
        };
        int band = y / 40;
        if (y % 40 < 2 || y % 40 >= 38) return 0;
        // P9 reverses colors from P8 but keeps physical row boundaries.
        return bars[pattern == 8 ? band : (11 - band)];
    }
    default: return 0x0000;
    }
}

static esp_err_t direct_patterns(void)
{
    static const char *names[] = {
        "unused", "vertical_1px", "horizontal_1px", "vertical_8px",
        "gradient_x", "gradient_y", "color_rows", "geometry",
        "horizontal_40px_y_markers", "horizontal_40px_reversed",
        "xy_corners_dark", "xy_corners_light",
        "xy_corners_dark_rot90", "xy_corners_light_rot90",
        "persistence_black", "persistence_white",
        "persistence_rot90", "persistence_black_final"
    };
    uint16_t *fb = pd_display_rgb_fb_get();
    if (!fb) {
        ESP_LOGE(TAG, "Direct RGB framebuffer inaccessible; abort patterns");
        return ESP_ERR_INVALID_STATE;
    }
    const size_t count = (size_t)RGB_WIDTH * RGB_HEIGHT;
    for (unsigned p = 1; p <= 17; ++p) {
        ESP_LOGI(TAG, "PATTERN P%u start t=%lld name=%s", p,
                 (long long)(esp_timer_get_time()/1000), names[p]);
        for (int y = 0; y < RGB_HEIGHT; ++y)
            for (int x = 0; x < RGB_WIDTH; ++x)
                fb[(size_t)y * RGB_WIDTH + x] = test_pattern_pixel((p == 12 || p == 13 || p == 16) ? (p == 13 ? 11 : 10) : p, y, RGB_HEIGHT - 1 - x);
        esp_err_t sync = esp_cache_msync(fb, count * sizeof(*fb), ESP_CACHE_MSYNC_FLAG_DIR_C2M);
        if (sync != ESP_OK) { ESP_LOGE(TAG, "PATTERN P%u msync failed: %s", p, esp_err_to_name(sync)); return sync; }
        pd_display_framebuffer_snapshot(names[p]);
        if (p == 8 || p == 9) {
            ESP_LOGI(TAG, "Y MAP P%u 12 bands: y=0-39,40-79,80-119,120-159,160-199,200-239,240-279,280-319,320-359,360-399,400-439,440-479; 2px black borders; P9 reverses band colors", p);
        }
        if (p == 10 || p == 11) {
            ESP_LOGI(TAG, "XY MAP P%u: (0,0)=RED top-left; (479,0)=GREEN top-right; (0,479)=BLUE bottom-left; (479,479)=YELLOW bottom-right; X ticks top; Y ticks left; global software rotation 90 clockwise", p);
        }
        if (p == 12 || p == 13 || p == 16) {
            ESP_LOGI(TAG, "ROT90 P%u: rotation commune 90 deg horaire des mires et LVGL", p);
        }
        if (p == 14 || p == 15 || p == 17) {
            ESP_LOGI(TAG, "PERSISTENCE P%u: effacement complet, observer ghosting sans LVGL", p);
        }
        const uint32_t dwell_ms = (p == 17) ? 15000 : (p >= 12 ? 8000 : (p >= 8 ? 10000 : 6000));
        vTaskDelay(pdMS_TO_TICKS(dwell_ms));
    }
    ESP_LOGI(TAG, "PATTERN done; transition LVGL");
    return ESP_OK;
}

esp_err_t pd_rgb_test_run(void)
{
    esp_lcd_panel_handle_t panel = pd_display_panel_get();
    if (!panel) return ESP_ERR_INVALID_STATE;
    static const struct { const char *name; uint16_t rgb565; } steps[] = {
        {"ROUGE", 0xF800}, {"VERT", 0x07E0}, {"BLEU", 0x001F},
        {"BLANC", 0xFFFF}, {"NOIR", 0x0000},
    };
    ESP_LOGI(TAG, "Debut test RGB : 5 aplats, 2 secondes chacun");
    for (size_t i = 0; i < sizeof(steps)/sizeof(steps[0]); i++) {
        ESP_LOGI(TAG, "APLAT %u/5 : %s (RGB565=0x%04x)", (unsigned)(i + 1), steps[i].name, steps[i].rgb565);
        esp_err_t err = fill_color(panel, steps[i].rgb565);
        if (err != ESP_OK) { ESP_LOGE(TAG, "Erreur RGB: %s", esp_err_to_name(err)); return err; }
        vTaskDelay(pdMS_TO_TICKS(2000));
    }
    ESP_LOGI(TAG, "Fin aplats RGB; debut mire hors LVGL");
    return direct_patterns();
}
