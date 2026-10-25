#pragma once

#include <stddef.h>
#include <stdint.h>
#include "esp_err.h"

typedef enum {
    PD_WIFI_INIT = 0,
    PD_WIFI_STA_CONNECTING,
    PD_WIFI_STA_ONLINE,
    PD_WIFI_AP_PORTAL,
    PD_WIFI_ERROR,
} pd_wifi_phase_t;

typedef struct {
    pd_wifi_phase_t phase;
    int last_disconnect_reason;
    char sta_ssid[33];
    char ip[16];
    char ap_ssid[33];
    /* Local UI only: do not include in HTTP status responses or diagnostic logs. */
    char ap_password[17];
} pd_wifi_status_t;

/* Non-blocking startup, designed for future Start screen polling from its LVGL task. */
esp_err_t pd_wifi_start(void);
void pd_wifi_status_get(pd_wifi_status_t *out);
