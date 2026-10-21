#include "diagnostics.h"
#include "lvgl.h"
#include "esp_timer.h"
#include "esp_heap_caps.h"
#include <inttypes.h>

/* Interface locale de demarrage. Aucune dependance EEZ Studio ni liaison reseau. */
static lv_obj_t *stats;
static lv_obj_t *feedback;
static unsigned int taps;

static void update_stats(lv_timer_t *timer)
{
    (void)timer;
    uint64_t sec = (uint64_t)esp_timer_get_time() / 1000000ULL;
    unsigned long heap_kib = (unsigned long)(heap_caps_get_free_size(MALLOC_CAP_INTERNAL) / 1024U);
    unsigned long psram_kib = (unsigned long)(heap_caps_get_free_size(MALLOC_CAP_SPIRAM) / 1024U);
    lv_label_set_text_fmt(stats,
                          "Uptime: %" PRIu64 " s\n"
                          "RAM interne libre: %lu KiB\n"
                          "PSRAM libre: %lu KiB",
                          sec, heap_kib, psram_kib);
}

static void refresh_clicked(lv_event_t *event)
{
    (void)event;
    taps++;
    update_stats(NULL);
    lv_label_set_text_fmt(feedback, "Tactile OK - appuis: %u", taps);
}

void pd_diagnostics_create(void)
{
    lv_obj_t *screen = lv_screen_active();
    lv_obj_set_style_bg_color(screen, lv_color_hex(0x101820), 0);
    lv_obj_set_style_bg_opa(screen, LV_OPA_COVER, 0);
    lv_obj_clear_flag(screen, LV_OBJ_FLAG_SCROLLABLE);

    lv_obj_t *title = lv_label_create(screen);
    lv_label_set_text(title, "PulseDeck");
    lv_obj_set_style_text_color(title, lv_color_white(), 0);
    lv_obj_align(title, LV_ALIGN_TOP_MID, 0, 24);

    lv_obj_t *subtitle = lv_label_create(screen);
    lv_label_set_text(subtitle, "Interface locale LVGL 9.5");
    lv_obj_set_style_text_color(subtitle, lv_color_hex(0xA7B8C8), 0);
    lv_obj_align(subtitle, LV_ALIGN_TOP_MID, 0, 58);

    lv_obj_t *panel = lv_obj_create(screen);
    lv_obj_set_size(panel, 428, 190);
    lv_obj_align(panel, LV_ALIGN_TOP_MID, 0, 98);
    lv_obj_set_style_bg_color(panel, lv_color_hex(0x203040), 0);
    lv_obj_set_style_border_width(panel, 0, 0);
    lv_obj_clear_flag(panel, LV_OBJ_FLAG_SCROLLABLE);

    stats = lv_label_create(panel);
    lv_obj_set_style_text_color(stats, lv_color_white(), 0);
    lv_obj_align(stats, LV_ALIGN_TOP_LEFT, 8, 8);

    lv_obj_t *network = lv_label_create(panel);
    lv_label_set_text(network, "Wi-Fi: non initialise\nMQTT: non initialise");
    lv_obj_set_style_text_color(network, lv_color_hex(0xA7B8C8), 0);
    lv_obj_align(network, LV_ALIGN_TOP_LEFT, 8, 90);

    lv_obj_t *button = lv_button_create(screen);
    lv_obj_set_size(button, 228, 52);
    lv_obj_align(button, LV_ALIGN_TOP_MID, 0, 316);
    lv_obj_add_event_cb(button, refresh_clicked, LV_EVENT_CLICKED, NULL);
    lv_obj_t *button_label = lv_label_create(button);
    lv_label_set_text(button_label, "Actualiser");
    lv_obj_center(button_label);

    feedback = lv_label_create(screen);
    lv_label_set_text(feedback, "Touchez Actualiser pour tester");
    lv_obj_set_style_text_color(feedback, lv_color_hex(0xA7B8C8), 0);
    lv_obj_align(feedback, LV_ALIGN_TOP_MID, 0, 394);

    update_stats(NULL);
    lv_timer_create(update_stats, 1000, NULL);
}
