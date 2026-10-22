#ifndef PD_SVG_TEST_H
#define PD_SVG_TEST_H

#include <stdbool.h>

/* LVGL must already be initialized. Call from pd_ui before ui_init().
 * Allocate a 2 MiB LVGL/TLSF pool in 8 MiB external PSRAM and test ARGB8888. */
bool pd_svg_test_prepare_memory(void);

/* Call in the same LVGL/UI task after ui_init(). One original clear-day SVG. */
void pd_svg_test_start(void);

#endif
