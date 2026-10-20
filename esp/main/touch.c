#include "touch.h"
#include "display.h"
#include "driver/i2c_master.h"
#include "esp_lcd_panel_io.h"
#include "esp_lcd_touch_gt911.h"
#include "esp_log.h"
static const char *TAG = "pd_touch";
static esp_lcd_touch_handle_t tp;
static lv_indev_t *pointer;

static void read_cb(lv_indev_t *indev, lv_indev_data_t *data)
{
    (void)indev;
    esp_lcd_touch_point_data_t pts[1] = {0};
    uint8_t count = 0;
    if (esp_lcd_touch_read_data(tp) == ESP_OK &&
        esp_lcd_touch_get_data(tp, pts, &count, 1) == ESP_OK && count) {
        data->state = LV_INDEV_STATE_PRESSED;
        data->point.x = pts[0].x;
        data->point.y = pts[0].y;
    } else {
        data->state = LV_INDEV_STATE_RELEASED;
    }
}

esp_err_t pd_touch_init(void)
{
    i2c_master_bus_config_t bus_cfg = {
        .clk_source = I2C_CLK_SRC_DEFAULT,
        .i2c_port = I2C_NUM_0,
        .sda_io_num = 19, .scl_io_num = 45,
        .glitch_ignore_cnt = 7,
        .flags.enable_internal_pullup = true,
    };
    i2c_master_bus_handle_t bus;
    esp_err_t err = i2c_new_master_bus(&bus_cfg, &bus);
    if (err != ESP_OK) return err;
    esp_lcd_panel_io_i2c_config_t io_cfg = ESP_LCD_TOUCH_IO_I2C_GT911_CONFIG();
    esp_lcd_panel_io_handle_t io;
    err = esp_lcd_new_panel_io_i2c(bus, &io_cfg, &io);
    if (err != ESP_OK) return err;
    esp_lcd_touch_config_t touch_cfg = {
        .x_max = 480, .y_max = 480,
        .rst_gpio_num = GPIO_NUM_NC, .int_gpio_num = GPIO_NUM_NC,
        .flags = { .swap_xy = 0, .mirror_x = 1, .mirror_y = 1 },
    };
    err = esp_lcd_touch_new_i2c_gt911(io, &touch_cfg, &tp);
    if (err != ESP_OK) { ESP_LOGW(TAG, "GT911 init failed: %s", esp_err_to_name(err)); return err; }
    pointer = lv_indev_create();
    if (!pointer) return ESP_ERR_NO_MEM;
    lv_indev_set_type(pointer, LV_INDEV_TYPE_POINTER);
    lv_indev_set_display(pointer, pd_display_get());
    lv_indev_set_read_cb(pointer, read_cb);
    ESP_LOGI(TAG, "GT911 linked (orientation tentative)");
    return ESP_OK;
}
