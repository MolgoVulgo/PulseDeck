idf_component_register(SRCS "main.c" "display.c" "touch.c" "lvgl_port.c" "diagnostics.c" "rgb_test.c"
                       INCLUDE_DIRS "."
                       REQUIRES esp_timer esp_system esp_lcd esp_driver_gpio esp_driver_i2c esp_psram esp_mm)
