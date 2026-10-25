#pragma once

#include <stdbool.h>
#include <stdint.h>
#include <time.h>
#include "esp_err.h"

/* Reserved for future configuration; NTP server and local timezone are independent.
 * The wire protocol returns UTC; use UTC0 until a local timezone setting exists. */
#define PD_NTP_POOL_DEFAULT "pool.ntp.org"
#define PD_NTP_TZ_DEFAULT "UTC0"
/* Period between regular SNTP correction attempts, not a UI clock tick. */
#define PD_NTP_RESYNC_INTERVAL_MS (60u * 60u * 1000u)

typedef enum {
    PD_NTP_WAIT_WIFI = 0,
    PD_NTP_SYNCING,
    PD_NTP_SYNCED,
    PD_NTP_TIMEOUT,
    PD_NTP_ERROR,
} pd_ntp_phase_t;

typedef struct {
    pd_ntp_phase_t phase;
    bool ever_synced;
    char pool[64];
    char timezone[8];
    int64_t last_sync_unix_utc; /* 0 until first confirmed SNTP callback */
    int64_t now_unix_utc;       /* 0 until first confirmed SNTP callback */
    esp_err_t last_error;
} pd_ntp_status_t;

/* Start asynchronous SNTP startup watcher. Safe to call after pd_wifi_start().
 * No LVGL dependency; Start screen can poll via pd_ntp_status_get(). */
esp_err_t pd_ntp_start(void);
void pd_ntp_status_get(pd_ntp_status_t *out);
/* False until a valid SNTP response. No local-time conversion is performed. */
bool pd_ntp_utc_now(struct tm *out);
