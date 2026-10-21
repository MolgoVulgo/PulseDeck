#pragma once

#include <stdbool.h>
#include <stdint.h>

/* Contrat local des valeurs de l'ecran esp32.
 * Une valeur *_valid=false est indisponible et ne doit jamais etre affichee
 * comme une mesure reelle. Les noms correspondent au contrat utilisateur.
 */
typedef struct {
    const char *system_status;              /* string */
    uint32_t cpu_freq_mhz;                  /* uint32 */
    float cpu_core0_pct;                   /* float */
    bool cpu_core0_valid;
    float cpu_core1_pct;                   /* float */
    bool cpu_core1_valid;
    float ram_used_pct;                    /* float */
    bool ram_valid;
    float psram_used_pct;                  /* float */
    bool psram_valid;
    uint32_t heap_min_free_kb;             /* uint32 */
    uint32_t heap_largest_free_kb;         /* uint32 */
    float lvgl_fps;                        /* float */
    bool lvgl_fps_valid;
    float lvgl_render_ms;                  /* float */
    bool lvgl_render_valid;
    float chip_temp_c;                     /* float */
    bool chip_temp_valid;
    int32_t wifi_rssi_dbm;                 /* int32 */
    bool wifi_rssi_valid;
    uint64_t uptime_sec;                   /* uint64 */
    const char *reset_reason;               /* string */
} pd_esp32_metrics_t;

/* Appeler dans l'unique tache UI, apres ui_init(). */
void pd_esp32_metrics_start(void);
