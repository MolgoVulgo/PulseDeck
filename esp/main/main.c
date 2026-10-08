#include "esp_log.h"
#include "esp_err.h"
#include "lvgl.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "lvgl_port.h"
#include "touch.h"
#include "diagnostics.h"

static const char *TAG = "pulsedeck";
void app_main(void)
{
    ESP_LOGI(TAG, "PulseDeck ESP32 : bring-up phase 0 / LVGL 9.5.0");
    esp_err_t err = pd_lvgl_port_init();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Bring-up arrete : ecran non valide (%s)", esp_err_to_name(err));
        return;
    }
    // Le tactile ne doit pas bloquer un diagnostic ecran deja operationnel.
    err = pd_touch_init();
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "Tactile indisponible (%s)", esp_err_to_name(err));
    }
    pd_diagnostics_create();
    while (true) {
        uint32_t delay_ms = lv_timer_handler();
        if (delay_ms < 5) delay_ms = 5;
        if (delay_ms > 50) delay_ms = 50;
        vTaskDelay(pdMS_TO_TICKS(delay_ms));
    }
}
