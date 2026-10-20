#include "lvgl_port.h"
#include "display.h"
#include "lvgl.h"
#include "esp_timer.h"
#include "esp_log.h"
static const char *TAG = "pd_lvgl";
static void tick(void *arg) { (void)arg; lv_tick_inc(2); }
esp_err_t pd_lvgl_port_init(void)
{
    lv_init();
    esp_err_t err = pd_display_init();
    if (err != ESP_OK) return err;
    if (!lv_display_get_default()) return ESP_ERR_INVALID_STATE;
    esp_timer_handle_t timer;
    esp_timer_create_args_t args = {.callback = tick, .name = "lvgl_tick"};
    err = esp_timer_create(&args, &timer);
    if (err != ESP_OK) return err;
    err = esp_timer_start_periodic(timer, 2000);
    if (err != ESP_OK) ESP_LOGE(TAG, "tick timer error: %s", esp_err_to_name(err));
    return err;
}
