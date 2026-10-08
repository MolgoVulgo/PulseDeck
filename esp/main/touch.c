#include "touch.h"
#include "esp_log.h"
static const char *TAG = "pd_touch";
esp_err_t pd_touch_init(void)
{
    ESP_LOGW(TAG, "Controleur tactile / I2C / IRQ non encore identifies");
    return ESP_ERR_NOT_SUPPORTED;
}
