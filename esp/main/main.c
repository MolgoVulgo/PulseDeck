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
    pd_enable_gesture_bubbling(ui_start);
    pd_enable_gesture_bubbling(ui_meteo);
    pd_enable_gesture_bubbling(ui_esp32);
    pd_esp32_metrics_start();

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
}
