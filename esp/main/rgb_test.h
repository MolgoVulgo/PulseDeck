#pragma once
#include "esp_err.h"
// Test RGB autonome : doit etre execute apres pd_display_init et avant le rendu LVGL.
esp_err_t pd_rgb_test_run(void);
