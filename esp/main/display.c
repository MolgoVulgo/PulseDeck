#include "display.h"
#include "esp_log.h"
static const char *TAG = "pd_display";
esp_err_t pd_display_init(void)
{
    ESP_LOGE(TAG, "ST7701/RGB non configure : brochage, timings et backlight requis");
    return ESP_ERR_NOT_SUPPORTED;
}
