#include "esp32_metrics.h"

#include <inttypes.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

#include "driver/temperature_sensor.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "sdkconfig.h"
#include "esp_err.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_rom_sys.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "lvgl.h"
#include "ui.h"

#define PD_METRICS_PERIOD_MS 1000U
#define PD_METRICS_LOG_PERIOD_SEC 30ULL
#define PD_RENDER_WINDOW_US 2000000LL
#define PD_INTERNAL_CAPS (MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT)
#define PD_PSRAM_CAPS (MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT)

static const char *TAG = "pd_esp32_metrics";
static temperature_sensor_handle_t s_tsens;
static int64_t s_render_begin_us;
static int64_t s_window_begin_us;
static uint64_t s_render_total_us;
static uint32_t s_render_count;
static float s_fps;
static float s_render_ms;
static bool s_fps_valid;
static bool s_render_valid;
static uint64_t s_next_log_sec = PD_METRICS_LOG_PERIOD_SEC;
#if CONFIG_FREERTOS_GENERATE_RUN_TIME_STATS && CONFIG_FREERTOS_USE_TRACE_FACILITY
static bool s_cpu_sample_started;
static uint64_t s_idle_previous[2];
static int64_t s_cpu_previous_us;
#endif

/* Estimateur d'occupation par coeur, derive du runtime reel des taches IDLE.
 * L'horloge de runtime FreeRTOS est explicitement configuree sur ESP_TIMER (1 MHz).
 * Aucune tache de mesure supplementaire ni arret du scheduler. */
static void pd_read_cpu_stats(pd_esp32_metrics_t *m)
{
    m->cpu_core0_valid = false;
    m->cpu_core1_valid = false;
#if CONFIG_FREERTOS_GENERATE_RUN_TIME_STATS && CONFIG_FREERTOS_USE_TRACE_FACILITY && CONFIG_FREERTOS_RUN_TIME_STATS_USING_ESP_TIMER && !CONFIG_FREERTOS_SMP
    if (CONFIG_FREERTOS_NUMBER_OF_CORES != 2) return;
    uint64_t idle_ticks[2];
    for (int i = 0; i < 2; ++i) {
        TaskHandle_t idle_handle = xTaskGetIdleTaskHandleForCore(i);
        if (!idle_handle) return;
        TaskStatus_t status = {0};
        /* eReady evite le calcul supplementaire de l'etat de la tache. */
        vTaskGetInfo(idle_handle, &status, pdFALSE, eReady);
        idle_ticks[i] = (uint64_t)status.ulRunTimeCounter;
    }
    const int64_t now_us = esp_timer_get_time();
    if (s_cpu_sample_started && now_us > s_cpu_previous_us) {
        const uint64_t interval_us = (uint64_t)(now_us - s_cpu_previous_us);
        if (interval_us >= 500000ULL && interval_us <= 10000000ULL) {
            float *values[2] = { &m->cpu_core0_pct, &m->cpu_core1_pct };
            bool *valids[2] = { &m->cpu_core0_valid, &m->cpu_core1_valid };
            for (int i = 0; i < 2; ++i) {
                if (idle_ticks[i] < s_idle_previous[i]) continue;
                const uint64_t idle_delta = idle_ticks[i] - s_idle_previous[i];
                /* Les taches IDLE mesurent le temps CPU libre, pas les ISR. */
                float busy_pct = 100.0f * (1.0f - (float)idle_delta / (float)interval_us);
                if (busy_pct < 0.0f) busy_pct = 0.0f;
                if (busy_pct > 100.0f) busy_pct = 100.0f;
                *values[i] = busy_pct;
                *valids[i] = true;
            }
        }
    }
    s_idle_previous[0] = idle_ticks[0];
    s_idle_previous[1] = idle_ticks[1];
    s_cpu_previous_us = now_us;
    s_cpu_sample_started = true;
#endif
}


/* Les evenements LVGL sont traites uniquement par la tache UI. */
static void pd_render_started(lv_event_t *event)
{
    (void)event;
    s_render_begin_us = esp_timer_get_time();
}

static void pd_render_finished(lv_event_t *event)
{
    (void)event;
    const int64_t now_us = esp_timer_get_time();
    if (s_render_begin_us <= 0 || now_us < s_render_begin_us) return;
    s_render_total_us += (uint64_t)(now_us - s_render_begin_us);
    s_render_count++;
    s_render_begin_us = 0;
}

static void pd_read_render_stats(void)
{
    const int64_t now_us = esp_timer_get_time();
    const int64_t elapsed_us = now_us - s_window_begin_us;
    if (elapsed_us < PD_RENDER_WINDOW_US) return;

    s_fps = (float)s_render_count * 1000000.0f / (float)elapsed_us;
    s_fps_valid = true;
    if (s_render_count > 0) {
        s_render_ms = (float)s_render_total_us / (1000.0f * (float)s_render_count);
        s_render_valid = true;
    } else {
        s_render_valid = false;
    }
    s_window_begin_us = now_us;
    s_render_total_us = 0;
    s_render_count = 0;
}

static const char *pd_reset_text(esp_reset_reason_t reason)
{
    switch (reason) {
    case ESP_RST_POWERON:   return "POWERON";
    case ESP_RST_EXT:       return "EXTERNAL";
    case ESP_RST_SW:        return "SOFTWARE";
    case ESP_RST_PANIC:     return "PANIC";
    case ESP_RST_INT_WDT:   return "INT_WDT";
    case ESP_RST_TASK_WDT:  return "TASK_WDT";
    case ESP_RST_WDT:       return "WDT";
    case ESP_RST_DEEPSLEEP: return "DEEPSLEEP";
    case ESP_RST_BROWNOUT:  return "BROWNOUT";
    case ESP_RST_SDIO:      return "SDIO";
    default:                return "UNKNOWN";
    }
}

static float pd_heap_used_percent(uint32_t caps, bool *valid)
{
    const size_t total = heap_caps_get_total_size(caps);
    if (total == 0) {
        *valid = false;
        return 0.0f;
    }
    size_t free_bytes = heap_caps_get_free_size(caps);
    if (free_bytes > total) free_bytes = total;
    *valid = true;
    return (float)(total - free_bytes) * 100.0f / (float)total;
}

static void pd_collect(pd_esp32_metrics_t *metrics)
{
    *metrics = (pd_esp32_metrics_t){0};
    metrics->system_status = "RUNNING";
    metrics->cpu_freq_mhz = esp_rom_get_cpu_ticks_per_us();

    pd_read_cpu_stats(metrics);

    metrics->ram_used_pct = pd_heap_used_percent(PD_INTERNAL_CAPS, &metrics->ram_valid);
    metrics->psram_used_pct = pd_heap_used_percent(PD_PSRAM_CAPS, &metrics->psram_valid);
    metrics->heap_min_free_kb = (uint32_t)(heap_caps_get_minimum_free_size(PD_INTERNAL_CAPS) / 1024U);
    metrics->heap_largest_free_kb = (uint32_t)(heap_caps_get_largest_free_block(PD_INTERNAL_CAPS) / 1024U);

    pd_read_render_stats();
    metrics->lvgl_fps = s_fps;
    metrics->lvgl_fps_valid = s_fps_valid;
    metrics->lvgl_render_ms = s_render_ms;
    metrics->lvgl_render_valid = s_render_valid;

    if (s_tsens && temperature_sensor_get_celsius(s_tsens, &metrics->chip_temp_c) == ESP_OK) {
        metrics->chip_temp_valid = true;
    }
    wifi_ap_record_t ap_info;
    if (esp_wifi_sta_get_ap_info(&ap_info) == ESP_OK) {
        metrics->wifi_rssi_dbm = (int32_t)ap_info.rssi;
        metrics->wifi_rssi_valid = true;
    }
    metrics->uptime_sec = (uint64_t)esp_timer_get_time() / 1000000ULL;
    metrics->reset_reason = pd_reset_text(esp_reset_reason());
}

static int32_t pd_percent_as_bar(float pct)
{
    if (pct <= 0.0f) return 0;
    if (pct >= 100.0f) return 100;
    return (int32_t)(pct + 0.5f);
}

static void pd_label_set_if_changed(lv_obj_t *obj, const char *text)
{
    if (obj && strcmp(lv_label_get_text(obj), text) != 0) lv_label_set_text(obj, text);
}

static void pd_render(const pd_esp32_metrics_t *metrics)
{
    if (!ui_esp32) return; /* La page peut etre detruite avant le timer. */
    char text[32];
    pd_label_set_if_changed(ui_esp32_system_status, metrics->system_status);
    snprintf(text, sizeof(text), "%" PRIu32 " MHz", metrics->cpu_freq_mhz);
    pd_label_set_if_changed(ui_esp32_cpu_freq_mhz, text);

    if (metrics->cpu_core0_valid) {
        snprintf(text, sizeof(text), "%.0f%%", (double)metrics->cpu_core0_pct);
        pd_label_set_if_changed(ui_esp32_core0_pct, text);
    } else pd_label_set_if_changed(ui_esp32_core0_pct, "N/A");
    if (metrics->cpu_core1_valid) {
        snprintf(text, sizeof(text), "%.0f%%", (double)metrics->cpu_core1_pct);
        pd_label_set_if_changed(ui_esp32_core1_pct, text);
    } else pd_label_set_if_changed(ui_esp32_core1_pct, "N/A");
    if (ui_esp32_bar_core0) lv_bar_set_value(ui_esp32_bar_core0,
        metrics->cpu_core0_valid ? pd_percent_as_bar(metrics->cpu_core0_pct) : 0, LV_ANIM_OFF);
    if (ui_esp32_bar_core1) lv_bar_set_value(ui_esp32_bar_core1,
        metrics->cpu_core1_valid ? pd_percent_as_bar(metrics->cpu_core1_pct) : 0, LV_ANIM_OFF);

    if (metrics->ram_valid) {
        snprintf(text, sizeof(text), "%ld%%", (long)pd_percent_as_bar(metrics->ram_used_pct));
        pd_label_set_if_changed(ui_esp32_ram_used_pct, text);
    } else pd_label_set_if_changed(ui_esp32_ram_used_pct, "N/A");
    if (ui_esp32_bar_ram_used) lv_bar_set_value(ui_esp32_bar_ram_used,
                                                 metrics->ram_valid ? pd_percent_as_bar(metrics->ram_used_pct) : 0,
                                                 LV_ANIM_OFF);

    if (metrics->psram_valid) {
        snprintf(text, sizeof(text), "%ld%%", (long)pd_percent_as_bar(metrics->psram_used_pct));
        pd_label_set_if_changed(ui_esp32_psram_used_pct, text);
    } else pd_label_set_if_changed(ui_esp32_psram_used_pct, "N/A");
    if (ui_esp32_bar_psram) lv_bar_set_value(ui_esp32_bar_psram,
                                              metrics->psram_valid ? pd_percent_as_bar(metrics->psram_used_pct) : 0,
                                              LV_ANIM_OFF);

    snprintf(text, sizeof(text), "%" PRIu32 " KB", metrics->heap_min_free_kb);
    pd_label_set_if_changed(ui_esp32_heap_min_free_kb, text);
    snprintf(text, sizeof(text), "%" PRIu32 " KB", metrics->heap_largest_free_kb);
    pd_label_set_if_changed(ui_esp32_heap_largest_free_kb, text);
    /* Aucun widget nomme n'existe dans l'export SquareLine courant pour les
     * six autres champs. Ils restent dans la structure et le diagnostic. */
}

static void pd_refresh(lv_timer_t *timer)
{
    (void)timer;
    pd_esp32_metrics_t metrics;
    pd_collect(&metrics);
    pd_render(&metrics);

    if (metrics.uptime_sec >= s_next_log_sec) {
        ESP_LOGI(TAG,
                 "uptime=%" PRIu64 "s cpu=%" PRIu32 "MHz ram=%.1f%% psram=%.1f%% "
                 "heap_min=%" PRIu32 "KiB largest=%" PRIu32 "KiB reset=%s",
                 metrics.uptime_sec, metrics.cpu_freq_mhz, metrics.ram_used_pct,
                 metrics.psram_used_pct, metrics.heap_min_free_kb,
                 metrics.heap_largest_free_kb, metrics.reset_reason);
        if (metrics.lvgl_fps_valid) {
            if (metrics.lvgl_render_valid) {
                ESP_LOGI(TAG, "LVGL rendered FPS=%.2f, avg render=%.2f ms (not UI loop rate)",
                         metrics.lvgl_fps, metrics.lvgl_render_ms);
            } else {
                ESP_LOGI(TAG, "LVGL no render event in current 2s window (static display possible)");
            }
        } else {
            ESP_LOGI(TAG, "LVGL render sampling not initialized");
        }
        if (metrics.chip_temp_valid) ESP_LOGI(TAG, "chip internal temperature=%.1f C", metrics.chip_temp_c);
        if (metrics.wifi_rssi_valid) ESP_LOGI(TAG, "Wi-Fi RSSI=%" PRId32 " dBm", metrics.wifi_rssi_dbm);
        else ESP_LOGI(TAG, "Wi-Fi RSSI unavailable (not connected/initialized)");
        if (metrics.cpu_core0_valid && metrics.cpu_core1_valid) {
            ESP_LOGI(TAG, "CPU core0=%.1f%% core1=%.1f%% (IDLE runtime delta, ~1s)",
                     metrics.cpu_core0_pct, metrics.cpu_core1_pct);
        } else {
            ESP_LOGW(TAG, "CPU per-core load unavailable (check FreeRTOS config and IDLE samples)");
        }
        s_next_log_sec = metrics.uptime_sec + PD_METRICS_LOG_PERIOD_SEC;
    }
}

void pd_esp32_metrics_start(void)
{
    temperature_sensor_config_t cfg = TEMPERATURE_SENSOR_CONFIG_DEFAULT(-10, 80);
    esp_err_t err = temperature_sensor_install(&cfg, &s_tsens);
    if (err == ESP_OK) err = temperature_sensor_enable(s_tsens);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "Chip temperature unavailable (%s)", esp_err_to_name(err));
        if (s_tsens) {
            temperature_sensor_uninstall(s_tsens);
            s_tsens = NULL;
        }
    }

    lv_display_t *disp = lv_display_get_default();
    if (disp) {
        lv_display_add_event_cb(disp, pd_render_started, LV_EVENT_RENDER_START, NULL);
        lv_display_add_event_cb(disp, pd_render_finished, LV_EVENT_RENDER_READY, NULL);
    }
    s_window_begin_us = esp_timer_get_time();
    pd_refresh(NULL);
    lv_timer_t *refresh_timer = lv_timer_create(pd_refresh, PD_METRICS_PERIOD_MS, NULL);
    if (!refresh_timer) ESP_LOGE(TAG, "Impossible de creer le timer metriques LVGL");
}
