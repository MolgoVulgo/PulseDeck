idf_component_register(
    SRCS "main.c" "display.c" "touch.c" "lvgl_port.c" "esp32_metrics.c" "pd_wifi.c" "pd_ntp.c" "pd_mqtt.c"
    INCLUDE_DIRS "."
    REQUIRES esp_timer esp_system esp_lcd esp_driver_gpio esp_driver_i2c esp_psram esp_mm
    PRIV_REQUIRES ui esp_rom esp_wifi esp_driver_tsens esp_netif esp_event nvs_flash esp_http_server lwip esp_hw_support mqtt
)
