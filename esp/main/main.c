#include <time.h>
#include <stdio.h>
#include <string.h>

#include "esp_log.h"
#include "esp_err.h"
#include "esp_heap_caps.h"
#include "lvgl.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "lvgl_port.h"
#include "touch.h"
#include "ui.h"
#include "display.h"
#include "esp32_metrics.h"
#include "pd_wifi.h"
#include "pd_ntp.h"
#include "pd_mqtt.h"

static const char *TAG = "pulsedeck";
#define PD_UI_TASK_STACK_BYTES 32768
#define PD_UI_TASK_PRIORITY 5
/* This PSRAM pool is production infrastructure for LVGL, not a rendering probe. */
#define PD_LVGL_POOL_BYTES (2u * 1024u * 1024u)
static void *s_lvgl_psram_block;
static lv_mem_pool_t s_lvgl_psram_pool;

static bool pd_init_lvgl_psram_pool(void)
{
    if (s_lvgl_psram_pool) return true;
    s_lvgl_psram_block = heap_caps_malloc(PD_LVGL_POOL_BYTES, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (!s_lvgl_psram_block) {
        ESP_LOGE(TAG, "LVGL PSRAM pool allocation failed");
        return false;
    }
    s_lvgl_psram_pool = lv_mem_add_pool(s_lvgl_psram_block, PD_LVGL_POOL_BYTES);
    if (!s_lvgl_psram_pool) {
        heap_caps_free(s_lvgl_psram_block);
        s_lvgl_psram_block = NULL;
        ESP_LOGE(TAG, "LVGL PSRAM pool registration failed");
        return false;
    }
    return true;
}

static void pd_enable_gesture_bubbling(lv_obj_t *parent)
{
    if (!parent) return;
    const uint32_t count = lv_obj_get_child_count(parent);
    for (uint32_t i = 0; i < count; ++i) {
        lv_obj_t *child = lv_obj_get_child(parent, i);
        lv_obj_add_flag(child, LV_OBJ_FLAG_GESTURE_BUBBLE);
        pd_enable_gesture_bubbling(child);
    }
}

/* Temporary Wi-Fi startup overlay; Start screen is inactive in SquareLine. */
static lv_obj_t *s_wifi_banner;
static lv_obj_t *s_wifi_banner_label;
static void pd_wifi_banner_refresh(lv_timer_t *timer)
{
    (void)timer;
    if (!s_wifi_banner || !s_wifi_banner_label) return;
    pd_wifi_status_t status;
    pd_wifi_status_get(&status);
    if (status.phase == PD_WIFI_STA_ONLINE) {
        lv_obj_add_flag(s_wifi_banner, LV_OBJ_FLAG_HIDDEN);
    } else {
        lv_obj_remove_flag(s_wifi_banner, LV_OBJ_FLAG_HIDDEN);
        if (status.phase == PD_WIFI_AP_PORTAL) {
            lv_label_set_text_fmt(s_wifi_banner_label,
                                  "Wi-Fi config: %s\nCle AP: %s  |  192.168.4.1",
                                  status.ap_ssid, status.ap_password);
        } else if (status.phase == PD_WIFI_STA_CONNECTING) {
            lv_label_set_text(s_wifi_banner_label, "Wi-Fi : connexion en cours...");
        } else if (status.phase == PD_WIFI_ERROR) {
            lv_label_set_text(s_wifi_banner_label, "Wi-Fi : erreur au demarrage");
        } else {
            lv_label_set_text(s_wifi_banner_label, "Wi-Fi : initialisation...");
        }
    }
}

static void pd_wifi_banner_create(void)
{
    s_wifi_banner = lv_obj_create(lv_layer_top());
    lv_obj_set_size(s_wifi_banner, 458, 70);
    lv_obj_align(s_wifi_banner, LV_ALIGN_BOTTOM_MID, 0, -7);
    lv_obj_set_style_bg_color(s_wifi_banner, lv_color_hex(0x142435), 0);
    lv_obj_set_style_bg_opa(s_wifi_banner, LV_OPA_COVER, 0);
    lv_obj_set_style_border_width(s_wifi_banner, 1, 0);
    lv_obj_set_style_pad_all(s_wifi_banner, 6, 0);
    lv_obj_clear_flag(s_wifi_banner, LV_OBJ_FLAG_CLICKABLE | LV_OBJ_FLAG_SCROLLABLE);
    s_wifi_banner_label = lv_label_create(s_wifi_banner);
    lv_obj_set_style_text_color(s_wifi_banner_label, lv_color_white(), 0);
    lv_label_set_long_mode(s_wifi_banner_label, LV_LABEL_LONG_WRAP);
    lv_obj_set_width(s_wifi_banner_label, 440);
    lv_obj_align(s_wifi_banner_label, LV_ALIGN_CENTER, 0, 0);
    pd_wifi_banner_refresh(NULL);
    lv_timer_create(pd_wifi_banner_refresh, 750, NULL);
}

/* Preserve the SquareLine-generated widgets. Update them exclusively from
 * the UI task, using the ESP32 software clock corrected by SNTP every hour. */
static void pd_meteo_clock_refresh(lv_timer_t *timer)
{
    (void)timer;
    if (!ui_meteo_hours || !ui_meteo_date) return;

    static bool displayed_unsynced;
    static int last_year = -1;
    static int last_yday = -1;
    static int last_hour = -1;
    static int last_minute = -1;
    struct tm utc;

    if (!pd_ntp_utc_now(&utc)) {
        if (!displayed_unsynced) {
            lv_label_set_text(ui_meteo_hours, "--:--");
            lv_label_set_text(ui_meteo_date, "Attente NTP");
            displayed_unsynced = true;
        }
        return;
    }

    if (!displayed_unsynced && last_year == utc.tm_year &&
        last_yday == utc.tm_yday && last_hour == utc.tm_hour &&
        last_minute == utc.tm_min) return;

    static const char * const day_names[] = {
        "Dimanche", "Lundi", "Mardi", "Mercredi", "Jeudi", "Vendredi", "Samedi"
    };
    static const char * const month_names[] = {
        "Janvier", "Février", "Mars", "Avril", "Mai", "Juin",
        "Juillet", "Août", "Septembre", "Octobre", "Novembre", "Décembre"
    };
    if (utc.tm_wday < 0 || utc.tm_wday >= 7 || utc.tm_mon < 0 || utc.tm_mon >= 12) return;
    lv_label_set_text_fmt(ui_meteo_hours, "%02d:%02d", utc.tm_hour, utc.tm_min);
    lv_label_set_text_fmt(ui_meteo_date, "%s %02d %s %04d",
                          day_names[utc.tm_wday], utc.tm_mday,
                          month_names[utc.tm_mon], utc.tm_year + 1900);
    last_year = utc.tm_year;
    last_yday = utc.tm_yday;
    last_hour = utc.tm_hour;
    last_minute = utc.tm_min;
    displayed_unsynced = false;
}

/* The Clock screen uses the same ESP32 wall clock as Meteo, corrected by
 * SNTP once per hour. All label writes stay on the LVGL UI task. */
static void pd_clock_refresh(lv_timer_t *timer)
{
    (void)timer;
    if (!ui_clock_hours) return;

    struct tm utc;
    char clock_text[9]; /* HH:MM:SS plus NUL */
    if (!pd_ntp_utc_now(&utc)) {
        snprintf(clock_text, sizeof(clock_text), "--:--:--");
    } else {
        /* 00..23, 00..59, 00..60 (leap second): always eight characters. */
        snprintf(clock_text, sizeof(clock_text), "%02d:%02d:%02d",
                 utc.tm_hour, utc.tm_min, utc.tm_sec);
    }

    /* Avoid invalidating the clock label four times each second. Compare
     * against the object itself, so even a recreated SquareLine screen gets
     * its correct value without relying on a stale static cache. */
    const char *shown = lv_label_get_text(ui_clock_hours);
    if (!shown || strcmp(shown, clock_text) != 0) {
        lv_label_set_text(ui_clock_hours, clock_text);
    }
}

/* The Monitoring screen is SquareLine-owned. Its MQTT catalogue is added
 * at runtime so re-exporting the generated UI does not overwrite this feature.
 * The entries are documented candidates, not broker-discovered subscriptions. */
static lv_obj_t *s_mqtt_screen;
static lv_obj_t *s_mqtt_status_label;

static void pd_monitoring_create(void)
{
    if (!ui_monitoring) return;
    if (s_mqtt_screen == ui_monitoring && s_mqtt_status_label &&
        lv_obj_is_valid(s_mqtt_status_label)) return;

    s_mqtt_screen = ui_monitoring;
    lv_obj_t *heading = lv_label_create(ui_monitoring);
    lv_label_set_text(heading, "MQTT / MONITORING");
    lv_obj_align(heading, LV_ALIGN_TOP_MID, 0, 12);

    s_mqtt_status_label = lv_label_create(ui_monitoring);
    lv_obj_set_width(s_mqtt_status_label, 452);
    lv_label_set_long_mode(s_mqtt_status_label, LV_LABEL_LONG_WRAP);
    lv_obj_align(s_mqtt_status_label, LV_ALIGN_TOP_MID, 0, 42);

    lv_obj_t *panel = lv_obj_create(ui_monitoring);
    lv_obj_set_size(panel, 452, 353);
    lv_obj_align(panel, LV_ALIGN_TOP_MID, 0, 117);
    lv_obj_set_style_pad_all(panel, 8, 0);
    lv_obj_set_scroll_dir(panel, LV_DIR_VER);

    lv_obj_t *catalogue = lv_label_create(panel);
    lv_obj_set_width(catalogue, 418);
    lv_label_set_long_mode(catalogue, LV_LABEL_LONG_WRAP);
    lv_label_set_text(catalogue, "Topics possibles / aucun abonnement actif");

    /* The 13 documented topics are generated from the same read-only table
     * exposed by pd_mqtt. No broker subscription or live discovery occurs. */
    char topics_text[1024];
    size_t used = 0;
    int n = snprintf(topics_text, sizeof(topics_text),
                     "TOPICS DISPONIBLES (0 abonnes)\n\n");
    if (n < 0 || (size_t)n >= sizeof(topics_text)) return;
    used = (size_t)n;
    for (size_t i = 0; i < pd_mqtt_topic_count(); ++i) {
        const char *topic = pd_mqtt_topic_at(i);
        n = snprintf(topics_text + used, sizeof(topics_text) - used,
                     "%s\n", topic);
        if (n < 0 || (size_t)n >= sizeof(topics_text) - used) break;
        used += (size_t)n;
    }
    lv_label_set_text(catalogue, topics_text);
    lv_obj_align(catalogue, LV_ALIGN_TOP_LEFT, 0, 0);
    /* The scrollable vertical list must not hijack horizontal screen swipes. */
    pd_enable_gesture_bubbling(ui_monitoring);
}

static void pd_monitoring_refresh(lv_timer_t *timer)
{
    (void)timer;
    pd_monitoring_create();
    if (!s_mqtt_status_label || !lv_obj_is_valid(s_mqtt_status_label)) return;
    pd_mqtt_status_t mqtt;
    pd_mqtt_status_get(&mqtt);
    const char *state = "Attente Wi-Fi";
    switch (mqtt.phase) {
    case PD_MQTT_CONNECTING: state = "Connexion..."; break;
    case PD_MQTT_CONNECTED: state = "Connecte"; break;
    case PD_MQTT_DISCONNECTED: state = "Deconnecte / reconnexion"; break;
    case PD_MQTT_ERROR: state = "Erreur / reconnexion"; break;
    case PD_MQTT_WAIT_WIFI: default: break;
    }
    char message[160];
    snprintf(message, sizeof(message), "Broker %s:%u\nEtat : %s",
             mqtt.broker, (unsigned)mqtt.port, state);
    const char *previous = lv_label_get_text(s_mqtt_status_label);
    if (!previous || strcmp(previous, message) != 0) {
        lv_label_set_text(s_mqtt_status_label, message);
    }
}

static void pd_ui_task(void *arg)
{
    (void)arg;
    esp_err_t err = pd_lvgl_port_init();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Display initialization failed: %s", esp_err_to_name(err));
        vTaskDelete(NULL);
        return;
    }
    err = pd_touch_init();
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "Touch unavailable: %s", esp_err_to_name(err));
    }
    if (!pd_init_lvgl_psram_pool()) {
        vTaskDelete(NULL);
        return;
    }
    ui_init();
    pd_enable_gesture_bubbling(ui_clock);
    pd_enable_gesture_bubbling(ui_meteo);
    pd_enable_gesture_bubbling(ui_monitoring);
    pd_enable_gesture_bubbling(ui_esp32);
    pd_monitoring_refresh(NULL);
    lv_timer_create(pd_monitoring_refresh, 1000, NULL);
    pd_esp32_metrics_start();
    pd_wifi_banner_create();
    pd_meteo_clock_refresh(NULL);
    lv_timer_create(pd_meteo_clock_refresh, 1000, NULL);
    pd_clock_refresh(NULL);
    lv_timer_create(pd_clock_refresh, 250, NULL);

    while (true) {
        uint32_t delay_ms = lv_timer_handler();
        if (delay_ms < 5) delay_ms = 5;
        if (delay_ms > 50) delay_ms = 50;
        vTaskDelay(pdMS_TO_TICKS(delay_ms));
    }
}

void app_main(void)
{
    BaseType_t ok = xTaskCreatePinnedToCore(pd_ui_task, "pd_ui", PD_UI_TASK_STACK_BYTES,
                                            NULL, PD_UI_TASK_PRIORITY, NULL, 1);
    if (ok != pdPASS) {
        ESP_LOGE(TAG, "UI task creation failed");
    }
    esp_err_t wifi_err = pd_wifi_start();
    if (wifi_err != ESP_OK) ESP_LOGE(TAG, "Wi-Fi start task failed: %s", esp_err_to_name(wifi_err));
    esp_err_t ntp_err = pd_ntp_start();
    if (ntp_err != ESP_OK) ESP_LOGE(TAG, "NTP start task failed: %s", esp_err_to_name(ntp_err));
    esp_err_t mqtt_err = pd_mqtt_start();
    if (mqtt_err != ESP_OK) ESP_LOGE(TAG, "MQTT start task failed: %s", esp_err_to_name(mqtt_err));
}
