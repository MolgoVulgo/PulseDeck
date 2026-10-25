#include "pd_ntp.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>

#include "esp_log.h"
#include "esp_netif.h"
#include "esp_netif_sntp.h"
#include "esp_sntp.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "pd_wifi.h"

#define PD_NTP_TASK_STACK_BYTES 4096
#define PD_NTP_TASK_PRIORITY 3
#define PD_NTP_POLL_MS 500
#define PD_NTP_SYNC_TIMEOUT_US (30000000LL)
#define PD_NTP_MIN_VALID_UNIX 1704067200LL /* 2024-01-01 UTC */

static const char *TAG = "pd_ntp";
/* Configurability placeholder: a future settings layer may populate this
 * before pd_ntp_start(). No setter/persistence is implemented in this patch. */
static char s_ntp_pool[64] = PD_NTP_POOL_DEFAULT;

static portMUX_TYPE s_lock = portMUX_INITIALIZER_UNLOCKED;
static pd_ntp_status_t s_status = {
    .phase = PD_NTP_WAIT_WIFI,
    .pool = PD_NTP_POOL_DEFAULT,
    .timezone = "UTC",
    .last_error = ESP_OK,
};
static TaskHandle_t s_ntp_worker;

static void pd_ntp_phase_set(pd_ntp_phase_t phase, esp_err_t err)
{
    portENTER_CRITICAL(&s_lock);
    s_status.phase = phase;
    s_status.last_error = err;
    portEXIT_CRITICAL(&s_lock);
}

/* The lwIP callback can arrive between the worker snapshot and its phase
 * update. Never overwrite its confirmed SYNCED state with SYNCING/TIMEOUT. */
static void pd_ntp_phase_if_unconfirmed(pd_ntp_phase_t phase, esp_err_t err)
{
    portENTER_CRITICAL(&s_lock);
    if (!s_status.ever_synced) {
        s_status.phase = phase;
        s_status.last_error = err;
    }
    portEXIT_CRITICAL(&s_lock);
}

/* Called by ESP-NETIF/lwIP after a genuine SNTP update, not by a timestamp
 * threshold or by a Wi-Fi event. Keep the callback short and task-independent. */
static void pd_ntp_synced(struct timeval *tv)
{
    if (tv == NULL || (int64_t)tv->tv_sec < PD_NTP_MIN_VALID_UNIX) {
        return;
    }
    portENTER_CRITICAL(&s_lock);
    s_status.ever_synced = true;
    s_status.last_sync_unix_utc = (int64_t)tv->tv_sec;
    s_status.phase = PD_NTP_SYNCED;
    s_status.last_error = ESP_OK;
    portEXIT_CRITICAL(&s_lock);
}

void pd_ntp_status_get(pd_ntp_status_t *out)
{
    if (out == NULL) return;
    portENTER_CRITICAL(&s_lock);
    *out = s_status;
    portEXIT_CRITICAL(&s_lock);
    /* Never expose a plausible-looking clock before receiving an NTP answer. */
    out->now_unix_utc = out->ever_synced ? (int64_t)time(NULL) : 0;
}

bool pd_ntp_utc_now(struct tm *out)
{
    if (out == NULL) return false;
    pd_ntp_status_t st;
    pd_ntp_status_get(&st);
    if (!st.ever_synced) return false;
    const time_t now = (time_t)st.now_unix_utc;
    return gmtime_r(&now, out) != NULL;
}

static void pd_ntp_worker_task(void *arg)
{
    (void)arg;
    /* Force UTC output regardless of toolchain default timezone. NTP itself
     * works in UTC and is independent from the configured server hostname. */
    if (setenv("TZ", PD_NTP_TZ_DEFAULT, 1) != 0) {
        ESP_LOGE(TAG, "Unable to set TZ=UTC0");
        pd_ntp_phase_set(PD_NTP_ERROR, ESP_FAIL);
        vTaskDelete(NULL);
        return;
    }
    tzset();

    bool sntp_started = false;
    bool seen_sync = false;
    int64_t online_since_us = 0;
    while (true) {
        pd_wifi_status_t wifi;
        pd_wifi_status_get(&wifi);
        const bool online = (wifi.phase == PD_WIFI_STA_ONLINE);
        pd_ntp_status_t st;
        pd_ntp_status_get(&st);
        if (!online) {
            online_since_us = 0;
            pd_ntp_phase_set(PD_NTP_WAIT_WIFI, ESP_OK);
        } else {
            if (online_since_us == 0) online_since_us = esp_timer_get_time();
            if (!sntp_started) {
                /* Network interface and IP already exist. SNTP is initialized
                 * once: lwIP maintains periodic polling and retry on reconnect. */
                /* Set the 1 h network correction interval BEFORE SNTP is
                 * initialized. The ESP32 system clock progresses autonomously
                 * between responses, including during Wi-Fi outages. */
                esp_sntp_set_sync_interval(PD_NTP_RESYNC_INTERVAL_MS);
                esp_sntp_config_t cfg = ESP_NETIF_SNTP_DEFAULT_CONFIG(s_ntp_pool);
                cfg.wait_for_sync = false; /* callback provides the confirmation */
                cfg.sync_cb = pd_ntp_synced;
                esp_err_t err = esp_netif_sntp_init(&cfg);
                if (err != ESP_OK) {
                    pd_ntp_phase_set(PD_NTP_ERROR, err);
                    ESP_LOGE(TAG, "SNTP init failed: %s", esp_err_to_name(err));
                    vTaskDelay(pdMS_TO_TICKS(5000));
                    continue;
                }
                sntp_started = true;
                ESP_LOGI(TAG, "NTP server=%s timezone=UTC period_ms=%u; waiting for sync",
                         s_ntp_pool, (unsigned)esp_sntp_get_sync_interval());
            }
            /* Read the status again: the lwIP callback may have arrived while
             * esp_netif_sntp_init ran. Avoid overwriting a successful sync. */
            pd_ntp_status_get(&st);
            if (st.ever_synced) {
                pd_ntp_phase_set(PD_NTP_SYNCED, ESP_OK);
                if (!seen_sync) {
                    seen_sync = true;
                    ESP_LOGI(TAG, "NTP synchronized (UTC), unix=%lld", (long long)st.last_sync_unix_utc);
                }
            } else if (esp_timer_get_time() - online_since_us >= PD_NTP_SYNC_TIMEOUT_US) {
                /* Only diagnostic: the lwIP SNTP client keeps retrying.
                 * A later genuine sync callback transitions to SYNCED. */
                pd_ntp_phase_if_unconfirmed(PD_NTP_TIMEOUT, ESP_ERR_TIMEOUT);
            } else {
                pd_ntp_phase_if_unconfirmed(PD_NTP_SYNCING, ESP_OK);
            }
        }
        vTaskDelay(pdMS_TO_TICKS(PD_NTP_POLL_MS));
    }
}

esp_err_t pd_ntp_start(void)
{
    if (s_ntp_worker != NULL) return ESP_ERR_INVALID_STATE;
    if (xTaskCreatePinnedToCore(pd_ntp_worker_task, "pd_ntp", PD_NTP_TASK_STACK_BYTES,
                                NULL, PD_NTP_TASK_PRIORITY, &s_ntp_worker, 0) != pdPASS) {
        pd_ntp_phase_set(PD_NTP_ERROR, ESP_ERR_NO_MEM);
        return ESP_ERR_NO_MEM;
    }
    return ESP_OK;
}
