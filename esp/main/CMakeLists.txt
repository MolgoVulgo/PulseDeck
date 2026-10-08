idf_component_register(SRCS "main.c" "display.c" "touch.c" "lvgl_port.c" "diagnostics.c"
                       INCLUDE_DIRS "."
                       REQUIRES esp_timer esp_system)
