#include "esp_log.h"
#include "esp_err.h"
#include "esp_heap_caps.h"
#include "lvgl.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "lvgl_port.h"
#include "touch.h"
#include "ui.h"
#include "esp32_metrics.h"

static const char *TAG = "pulsedeck";
/* ESP-021 overflowed the default app_main task stack while constructing LVGL widgets.
 * Keep all LVGL initialization, widget creation and timer handling in one task.
 * ESP-IDF FreeRTOS xTaskCreate stack depth is expressed in BYTES.
 */
#define PD_UI_TASK_STACK_BYTES 8192
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
    ui_init();
    pd_esp32_metrics_start();
    TickType_t last_stack_log = xTaskGetTickCount();
    while (true) {
        uint32_t delay_ms = lv_timer_handler();
        if (delay_ms < 5) delay_ms = 5;
        if (delay_ms > 50) delay_ms = 50;
        if ((xTaskGetTickCount() - last_stack_log) >= pdMS_TO_TICKS(30000)) {
            ESP_LOGI(TAG, "UI task stack high-water mark: %u bytes",
                     (unsigned)uxTaskGetStackHighWaterMark(NULL));
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
