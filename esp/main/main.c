#include "esp_log.h"
#include "esp_err.h"
#include "esp_heap_caps.h"
#include "esp_timer.h"
#include "lvgl.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "lvgl_port.h"
#include "touch.h"
#include "ui.h"
#include "svg_test.h"

static const char *TAG = "pulsedeck";
/* ESP-021 overflowed the default app_main task stack while constructing LVGL widgets.
 * Keep all LVGL initialization, widget creation and timer handling in one task.
 * ESP-IDF FreeRTOS xTaskCreate stack depth is expressed in BYTES.
 */
#define PD_UI_TASK_STACK_BYTES 16384
#define PD_UI_TASK_PRIORITY 5

static void pd_ui_task(void *arg)
{
    (void)arg;
    esp_log_level_set("pd_display", ESP_LOG_DEBUG);
    esp_log_level_set("lcd_panel.rgb", ESP_LOG_DEBUG);
    esp_log_level_set("st7701", ESP_LOG_DEBUG);
    ESP_LOGI(TAG, "PulseDeck ESP32 : interface locale LVGL 9.5.0 (sans mires RGB)");
    esp_err_t err = pd_lvgl_port_init();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Bring-up arrete : ecran non valide (%s)", esp_err_to_name(err));
        vTaskDelete(NULL);
        return;
    }
    // Le tactile reste optionnel pendant le demarrage de l’interface locale.
    err = pd_touch_init();
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "Tactile indisponible (%s)", esp_err_to_name(err));
    }
    /* test_002: after lv_init() in pd_lvgl_port_init(), before widgets.
     * A built-in 64 KiB LVGL heap cannot hold the ARGB8888 SVG scratch buffer.
     * Stop safely with a log if the PSRAM pool / 480x80 probe fails. */
    if (!pd_svg_test_prepare_memory()) {
        ESP_LOGE(TAG, "test_002: PSRAM LVGL pool/probe failed; Lottie rendering skipped");
        vTaskDelete(NULL);
        return;
    }
    ui_init();
    pd_svg_test_start();
    TickType_t last_stack_log = xTaskGetTickCount();
    bool first_handler = true;
    while (true) {
        int64_t begin_us = 0;
        if (first_handler) {
            ESP_LOGI(TAG, "test_002: ENTER first lv_timer_handler (one Lottie + LVGL PSRAM pool)");
            begin_us = esp_timer_get_time();
        }
        uint32_t delay_ms = lv_timer_handler();
        if (first_handler) {
            const long long elapsed_ms = (long long)((esp_timer_get_time() - begin_us) / 1000);
            ESP_LOGI(TAG, "test_002: EXIT first lv_timer_handler after %lld ms", elapsed_ms);
            first_handler = false;
        }
        if (delay_ms < 5) delay_ms = 5;
        if (delay_ms > 50) delay_ms = 50;
        if ((xTaskGetTickCount() - last_stack_log) >= pdMS_TO_TICKS(5000)) {
            ESP_LOGI(TAG, "test_002: alive; stack high-water=%u bytes; heap8=%lu B",
                     (unsigned)uxTaskGetStackHighWaterMark(NULL),
                     (unsigned long)heap_caps_get_free_size(MALLOC_CAP_8BIT));
            last_stack_log = xTaskGetTickCount();
        }
        vTaskDelay(pdMS_TO_TICKS(delay_ms));
    }
}

void app_main(void)
{
    BaseType_t ok = xTaskCreate(pd_ui_task, "pd_ui", PD_UI_TASK_STACK_BYTES,
                                NULL, PD_UI_TASK_PRIORITY, NULL);
    if (ok != pdPASS) {
        ESP_LOGE(TAG, "Cannot create LVGL UI task (stack=%u bytes)",
                 (unsigned)PD_UI_TASK_STACK_BYTES);
    }
}
