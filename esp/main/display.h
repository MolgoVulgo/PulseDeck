#pragma once
#include "esp_err.h"
// Initialise le controleur RGB ST7701 et enregistre un display LVGL.
// Non disponible tant que le brochage et les timings reels ne sont pas valides.
esp_err_t pd_display_init(void);
