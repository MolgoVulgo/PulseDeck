#pragma once
#include "esp_err.h"
// Initialise LVGL 9.5 et exige un display reel avant tout rendu.
esp_err_t pd_lvgl_port_init(void);
