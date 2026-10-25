#include "pd_mqtt.h"

#include "esp_event.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "mqtt_client.h"
#include "pd_wifi.h"

#define PD_MQTT_WORKER_STACK 4096
#define PD_MQTT_WORKER_PRIORITY 3
#define PD_MQTT_WIFI_POLL_MS 500

static const char *TAG = "pd_mqtt";
/* Reserved for future persisted/configurable broker settings. Immutable while
 * an MQTT client is running: ESP-MQTT retains configuration references. */
static char s_broker_host[64] = PD_MQTT_BROKER_DEFAULT;
static uint16_t s_broker_port = PD_MQTT_PORT_DEFAULT;
static portMUX_TYPE s_lock = portMUX_INITIALIZER_UNLOCKED;
static pd_mqtt_status_t s_status = {
    .phase = PD_MQTT_WAIT_WIFI,
    .broker = PD_MQTT_BROKER_DEFAULT,
    .port = PD_MQTT_PORT_DEFAULT,
    .last_error = ESP_OK,
};
static TaskHandle_t s_worker;
/* Protected by s_lock, used to reject late callbacks after Wi-Fi loss. */
static bool s_wifi_allowed;

/* Contract: docs/pi/MQTT.md, matched against hub/src/pulsedeck_hub/mqtt/topics.py.
 * No wildcard SUBSCRIBE. Placeholder <id> is a logical ID, not a literal topic. */
static const char *const s_topics[] = {
    "pulsedeck/v1/system/availability",
    "pulsedeck/v1/weather/availability",
    "pulsedeck/v1/weather/current",
    "pulsedeck/v1/weather/hourly",
    "pulsedeck/v1/weather/daily",
    "pulsedeck/v1/news/availability",
    "pulsedeck/v1/news/latest",
    "pulsedeck/v1/machine/<id>/availability",
    "pulsedeck/v1/machine/<id>/dashboard",
    "pulsedeck/v1/printer/<id>/availability",
    "pulsedeck/v1/printer/<id>/status",
    "pulsedeck/v1/printer/<id>/job",
    "pulsedeck/v1/printer/<id>/thumbnail",
};

size_t pd_mqtt_topic_count(void)
{
    return sizeof(s_topics) / sizeof(s_topics[0]);
}

const char *pd_mqtt_topic_at(size_t index)
{
    return index < pd_mqtt_topic_count() ? s_topics[index] : NULL;
}

void pd_mqtt_status_get(pd_mqtt_status_t *out)
{
    if (!out) return;
    portENTER_CRITICAL(&s_lock);
    *out = s_status;
    portEXIT_CRITICAL(&s_lock);
}

static void pd_mqtt_set_phase(pd_mqtt_phase_t phase, esp_err_t err)
{
    portENTER_CRITICAL(&s_lock);
    s_status.phase = phase;
    s_status.last_error = err;
    portEXIT_CRITICAL(&s_lock);
}

/* Runs in ESP-MQTT event-loop context. Never uses LVGL, performs a SUBSCRIBE,
 * calls stop/destroy, or blocks on the Wi-Fi worker. */
static void pd_mqtt_on_event(void *arg, esp_event_base_t base,
                             int32_t event_id, void *event_data)
{
    (void)arg;
    (void)base;
    const esp_mqtt_event_handle_t event = (esp_mqtt_event_handle_t)event_data;
    bool report_event = false;
    uint32_t connection_count = 0;
    const esp_mqtt_event_id_t kind = (esp_mqtt_event_id_t)event_id;

    /* Change shared status atomically, but never log while holding s_lock:
     * ESP_LOG may block, and the callback runs in the MQTT event context. */
    portENTER_CRITICAL(&s_lock);
    if (s_wifi_allowed) {
        switch (kind) {
        case MQTT_EVENT_CONNECTED:
            s_status.phase = PD_MQTT_CONNECTED;
            s_status.last_error = ESP_OK;
            s_status.ever_connected = true;
            s_status.connection_count++;
            connection_count = s_status.connection_count;
            report_event = true;
            break;
        case MQTT_EVENT_DISCONNECTED:
            s_status.phase = PD_MQTT_DISCONNECTED;
            report_event = true;
            break;
        case MQTT_EVENT_ERROR:
            s_status.phase = PD_MQTT_ERROR;
            s_status.last_error = ESP_FAIL;
            report_event = true;
            break;
        default:
            break;
        }
    }
    portEXIT_CRITICAL(&s_lock);
    if (!report_event) return;

    /* CONNECTED is evidence of the MQTT CONNACK, unlike 'client started'.
     * No topic names, payloads, credentials or Wi-Fi identifiers are logged. */
    switch (kind) {
    case MQTT_EVENT_CONNECTED:
        ESP_LOGI(TAG, "MQTT_EVENT_CONNECTED broker=%s:%u count=%lu session_present=%d",
                 s_broker_host, (unsigned)s_broker_port,
                 (unsigned long)connection_count, event ? event->session_present : -1);
        break;
    case MQTT_EVENT_DISCONNECTED:
        ESP_LOGW(TAG, "MQTT_EVENT_DISCONNECTED broker=%s:%u; reconnect enabled",
                 s_broker_host, (unsigned)s_broker_port);
        break;
    case MQTT_EVENT_ERROR: {
        const esp_mqtt_error_codes_t *error = event ? event->error_handle : NULL;
        if (!error) {
            ESP_LOGE(TAG, "MQTT_EVENT_ERROR broker=%s:%u (no error details)",
                     s_broker_host, (unsigned)s_broker_port);
        } else if (error->error_type == MQTT_ERROR_TYPE_CONNECTION_REFUSED) {
            ESP_LOGE(TAG, "MQTT_EVENT_ERROR refused: CONNACK return_code=%d",
                     (int)error->connect_return_code);
        } else if (error->error_type == MQTT_ERROR_TYPE_TCP_TRANSPORT) {
            ESP_LOGE(TAG, "MQTT_EVENT_ERROR transport: esp_err=0x%x socket_errno=%d tls_stack_err=0x%x",
                     (unsigned)error->esp_tls_last_esp_err,
                     error->esp_transport_sock_errno,
                     (unsigned)error->esp_tls_stack_err);
        } else {
            ESP_LOGE(TAG, "MQTT_EVENT_ERROR type=%d", (int)error->error_type);
        }
        break;
    }
    default:
        break;
    }
}

static void pd_mqtt_worker(void *arg)
{
    (void)arg;
    /* IDF 5.5 includes MQTT as the built-in 'mqtt' component.
     * MQTT 3.1.1, anonymous TCP/1883 match the current LAN-only Pi broker.
     * Leave the ESP-MQTT client-id default (unique per chip) and its internal
     * broker reconnection enabled. No application topic subscription here. */
    const esp_mqtt_client_config_t config = {
        .broker.address.hostname = s_broker_host,
        .broker.address.port = s_broker_port,
        .broker.address.transport = MQTT_TRANSPORT_OVER_TCP,
        .session.protocol_ver = MQTT_PROTOCOL_V_3_1_1,
    };
    /* Defer client setup until Wi-Fi/IP are initialized and STA is online. */
    esp_mqtt_client_handle_t client = NULL;
    esp_err_t err = ESP_OK;
    bool running = false;
    while (true) {
        pd_wifi_status_t wifi;
        pd_wifi_status_get(&wifi);
        bool online = wifi.phase == PD_WIFI_STA_ONLINE;
        if (online && !running) {
            if (client == NULL) {
                client = esp_mqtt_client_init(&config);
                if (client == NULL) {
                    ESP_LOGE(TAG, "MQTT client initialization failed");
                    pd_mqtt_set_phase(PD_MQTT_ERROR, ESP_FAIL);
                    break;
                }
                err = esp_mqtt_client_register_event(client, ESP_EVENT_ANY_ID,
                                                    pd_mqtt_on_event, NULL);
                if (err != ESP_OK) {
                    ESP_LOGE(TAG, "MQTT event registration failed: %s", esp_err_to_name(err));
                    pd_mqtt_set_phase(PD_MQTT_ERROR, err);
                    esp_mqtt_client_destroy(client);
                    client = NULL;
                    break;
                }
            }
            portENTER_CRITICAL(&s_lock);
            s_wifi_allowed = true;
            s_status.phase = PD_MQTT_CONNECTING;
            s_status.last_error = ESP_OK;
            portEXIT_CRITICAL(&s_lock);
            err = esp_mqtt_client_start(client);
            if (err == ESP_OK) {
                running = true;
                ESP_LOGI(TAG, "MQTT client started: %s:%u (no subscriptions)",
                         s_broker_host, (unsigned)s_broker_port);
            } else {
                ESP_LOGW(TAG, "MQTT client start failed: %s", esp_err_to_name(err));
                pd_mqtt_set_phase(PD_MQTT_ERROR, err);
                /* Retrying start is not specified after a partial start failure.
                 * Fail closed: avoid racing an incompletely started client. */
                break;
            }
        } else if (!online && running) {
            portENTER_CRITICAL(&s_lock);
            s_wifi_allowed = false;
            s_status.phase = PD_MQTT_WAIT_WIFI;
            portEXIT_CRITICAL(&s_lock);
            err = esp_mqtt_client_stop(client); /* task, never MQTT callback */
            if (err != ESP_OK) {
                ESP_LOGE(TAG, "MQTT client stop failed: %s", esp_err_to_name(err));
                pd_mqtt_set_phase(PD_MQTT_ERROR, err);
                break;
            }
            running = false;
        } else if (!online) {
            pd_mqtt_set_phase(PD_MQTT_WAIT_WIFI, ESP_OK);
        }
        vTaskDelay(pdMS_TO_TICKS(PD_MQTT_WIFI_POLL_MS));
    }
    /* Fatal engine state: preserve client for diagnostics, do not destroy an
     * incompletely stopped client while its event task might still run. */
    portENTER_CRITICAL(&s_lock);
    s_wifi_allowed = false;
    portEXIT_CRITICAL(&s_lock);
    vTaskDelete(NULL);
}

esp_err_t pd_mqtt_start(void)
{
    if (s_worker) return ESP_ERR_INVALID_STATE;
    BaseType_t ok = xTaskCreatePinnedToCore(pd_mqtt_worker, "pd_mqtt",
                   PD_MQTT_WORKER_STACK, NULL, PD_MQTT_WORKER_PRIORITY,
                   &s_worker, 0);
    return ok == pdPASS ? ESP_OK : ESP_ERR_NO_MEM;
}
