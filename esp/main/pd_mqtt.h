#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "esp_err.h"

/* LAN-only Mosquitto, as documented in docs/pi/MQTT.md. Future configuration
 * may change host and port before pd_mqtt_start(); no settings UI or NVS yet. */
#define PD_MQTT_BROKER_DEFAULT "192.168.0.250"
#define PD_MQTT_PORT_DEFAULT 1883
#define PD_MQTT_NAMESPACE "pulsedeck/v1"

typedef enum {
    PD_MQTT_WAIT_WIFI = 0,
    PD_MQTT_CONNECTING,
    PD_MQTT_CONNECTED,
    PD_MQTT_DISCONNECTED,
    PD_MQTT_ERROR,
} pd_mqtt_phase_t;

typedef struct {
    pd_mqtt_phase_t phase;
    char broker[64];
    uint16_t port;
    bool ever_connected;
    uint32_t connection_count;
    esp_err_t last_error;
} pd_mqtt_status_t;

/* Asynchronous connection engine. No subscriptions or publications are made. */
esp_err_t pd_mqtt_start(void);
void pd_mqtt_status_get(pd_mqtt_status_t *out);

/* Potential subscriptions documented by the Pi MQTT contract, NOT discovered
 * from the broker and NOT subscribed to. Entries with <id> are templates. */
size_t pd_mqtt_topic_count(void);
const char *pd_mqtt_topic_at(size_t index);
