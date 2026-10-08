#include "lvgl_port.h"
#include "display.h"
#include "lvgl.h"
#include "esp_log.h"
static const char *TAG = "pd_lvgl";
esp_err_t pd_lvgl_port_init(void)
{
    lv_init();
    esp_err_t err = pd_display_init();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Aucun ecran disponible : rendu LVGL interdit (%s)", esp_err_to_name(err));
        return err;
    }
    if (lv_display_get_default() == NULL) {
        ESP_LOGE(TAG, "Driver display n'a pas enregistre de display LVGL");
        return ESP_ERR_INVALID_STATE;
    }
    return ESP_OK;
}
