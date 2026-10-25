#include "pd_wifi.h"

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "freertos/semphr.h"
#include "esp_event.h"
#include "esp_http_server.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "esp_wifi_default.h"
#include "lwip/ip4_addr.h"
#include "nvs.h"
#include "nvs_flash.h"

#define PD_WIFI_AP_PASSWORD "PulseDeck"
#define PD_WIFI_STA_HOSTNAME "PulseDesk"
#define PD_WIFI_MAX_RETRIES 3
#define PD_WIFI_CONNECT_MS 20000
#define PD_WIFI_SCAN_LIMIT 16
#define PD_WIFI_POST_MAX 512
#define PD_WIFI_QUEUE_SIZE 8

static const char *TAG = "pd_wifi";
static QueueHandle_t s_events;
static SemaphoreHandle_t s_scan_lock; /* Serializes radio scan and connect attempts. */
static httpd_handle_t s_httpd;
static portMUX_TYPE s_status_lock = portMUX_INITIALIZER_UNLOCKED;
static pd_wifi_status_t s_status;
static bool s_ap_active;
static bool s_connecting;
static bool s_pending_save;
static unsigned int s_attempts;
static int64_t s_deadline_us;
static char s_ssid[33];
static char s_password[65];

typedef enum {
    PD_EVT_DISCONNECT, PD_EVT_GOT_IP, PD_EVT_SUBMIT
} pd_event_kind_t;
typedef struct {
    pd_event_kind_t kind;
    int reason;
    char ssid[33];
    char password[65];
    char ip[16];
} pd_event_t;

static void pd_status_phase(pd_wifi_phase_t phase, int reason)
{
    portENTER_CRITICAL(&s_status_lock);
    s_status.phase = phase;
    s_status.last_disconnect_reason = reason;
    portEXIT_CRITICAL(&s_status_lock);
}

void pd_wifi_status_get(pd_wifi_status_t *out)
{
    if (!out) return;
    portENTER_CRITICAL(&s_status_lock);
    *out = s_status;
    portEXIT_CRITICAL(&s_status_lock);
}

static bool pd_wifi_auth_error(int reason)
{
    return reason == WIFI_REASON_AUTH_FAIL ||
           reason == WIFI_REASON_HANDSHAKE_TIMEOUT ||
           reason == WIFI_REASON_4WAY_HANDSHAKE_TIMEOUT ||
           reason == WIFI_REASON_802_1X_AUTH_FAILED;
}

/* One versioned NVS blob keeps the SSID/password pair coherent across reboots. */
#define PD_NVS_MAGIC 0x50445731u  /* "PDW1" */
typedef struct {
    uint32_t magic;
    char ssid[33];
    char password[65];
} pd_nvs_creds_t;

static esp_err_t pd_read_nvs(void)
{
    nvs_handle_t handle;
    esp_err_t err = nvs_open("pd_wifi", NVS_READONLY, &handle);
    if (err == ESP_ERR_NVS_NOT_FOUND) return ESP_ERR_NOT_FOUND;
    if (err != ESP_OK) return err;
    pd_nvs_creds_t value = {0};
    size_t len = sizeof(value);
    err = nvs_get_blob(handle, "sta_creds_v1", &value, &len);
    nvs_close(handle);
    if (err != ESP_OK || len != sizeof(value) || value.magic != PD_NVS_MAGIC ||
        !memchr(value.ssid, 0, sizeof(value.ssid)) ||
        !memchr(value.password, 0, sizeof(value.password))) return ESP_ERR_NOT_FOUND;
    size_t slen = strlen(value.ssid), plen = strlen(value.password);
    if (slen == 0 || slen > 32 || (plen != 0 && (plen < 8 || plen > 63))) return ESP_ERR_NOT_FOUND;
    memcpy(s_ssid, value.ssid, sizeof(s_ssid));
    memcpy(s_password, value.password, sizeof(s_password));
    memset(&value, 0, sizeof(value));
    return ESP_OK;
}

static esp_err_t pd_save_nvs(void)
{
    pd_nvs_creds_t value = {.magic = PD_NVS_MAGIC};
    memcpy(value.ssid, s_ssid, sizeof(value.ssid));
    memcpy(value.password, s_password, sizeof(value.password));
    nvs_handle_t handle;
    esp_err_t err = nvs_open("pd_wifi", NVS_READWRITE, &handle);
    if (err != ESP_OK) return err;
    err = nvs_set_blob(handle, "sta_creds_v1", &value, sizeof(value));
    if (err == ESP_OK) err = nvs_commit(handle);
    nvs_close(handle);
    memset(&value, 0, sizeof(value));
    return err;
}

static void pd_driver_event(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    (void)arg;
    pd_event_t ev = {0};
    if (base == WIFI_EVENT && id == WIFI_EVENT_STA_DISCONNECTED) {
        ev.kind = PD_EVT_DISCONNECT;
        ev.reason = ((wifi_event_sta_disconnected_t *)data)->reason;
    } else if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) {
        ev.kind = PD_EVT_GOT_IP;
        const ip_event_got_ip_t *ip = (const ip_event_got_ip_t *)data;
        snprintf(ev.ip, sizeof(ev.ip), IPSTR, IP2STR(&ip->ip_info.ip));
    } else {
        return;
    }
    if (s_events && xQueueSend(s_events, &ev, 0) != pdTRUE) {
        ESP_LOGE(TAG, "Wi-Fi event queue full; reboot required to restore consistent state");
        pd_status_phase(PD_WIFI_ERROR, -1);
    }
}

static void pd_make_ap_credentials(void)
{
    uint8_t mac[6];
    ESP_ERROR_CHECK(esp_wifi_get_mac(WIFI_IF_STA, mac));
    char name[33];
    snprintf(name, sizeof(name), "PulseDeck-%02X%02X%02X", mac[3], mac[4], mac[5]);
    portENTER_CRITICAL(&s_status_lock);
    memcpy(s_status.ap_ssid, name, strlen(name) + 1);
    memcpy(s_status.ap_password, PD_WIFI_AP_PASSWORD, sizeof(PD_WIFI_AP_PASSWORD));
    portEXIT_CRITICAL(&s_status_lock);
}

static esp_err_t pd_ap_enable(void)
{
    if (s_ap_active) {
        s_connecting = false;
        pd_wifi_status_t previous;
        pd_wifi_status_get(&previous);
        pd_status_phase(PD_WIFI_AP_PORTAL, previous.last_disconnect_reason);
        return ESP_OK;
    }
    wifi_config_t ap = {0};
    pd_wifi_status_t snapshot;
    pd_wifi_status_get(&snapshot);
    memcpy(ap.ap.ssid, snapshot.ap_ssid, strlen(snapshot.ap_ssid));
    memcpy(ap.ap.password, snapshot.ap_password, strlen(snapshot.ap_password));
    ap.ap.ssid_len = strlen(snapshot.ap_ssid);
    ap.ap.channel = 1;
    ap.ap.max_connection = 3;
    ap.ap.authmode = WIFI_AUTH_WPA2_PSK;
    /* Never start AP with the driver's unspecified default configuration. */
    esp_err_t err = esp_wifi_stop();
    if (err == ESP_OK) err = esp_wifi_set_mode(WIFI_MODE_APSTA);
    if (err == ESP_OK) err = esp_wifi_set_config(WIFI_IF_AP, &ap);
    if (err == ESP_OK) err = esp_wifi_start();
    if (err != ESP_OK) return err;
    s_ap_active = true;
    s_connecting = false;
    pd_status_phase(PD_WIFI_AP_PORTAL, snapshot.last_disconnect_reason);
    ESP_LOGI(TAG, "Provisioning AP enabled; open http://192.168.4.1 (key displayed on LCD)");
    return ESP_OK;
}

static esp_err_t pd_sta_connect(bool save_on_success)
{
    wifi_config_t sta = {0};
    memcpy(sta.sta.ssid, s_ssid, strlen(s_ssid));
    memcpy(sta.sta.password, s_password, strlen(s_password));
    sta.sta.threshold.authmode = WIFI_AUTH_OPEN;
    sta.sta.pmf_cfg.capable = true;
    sta.sta.pmf_cfg.required = false;
    if (xSemaphoreTake(s_scan_lock, pdMS_TO_TICKS(15000)) != pdTRUE) return ESP_ERR_TIMEOUT;
    esp_err_t err = esp_wifi_set_config(WIFI_IF_STA, &sta);
    if (err == ESP_OK) err = esp_wifi_connect();
    xSemaphoreGive(s_scan_lock);
    if (err == ESP_OK) {
        s_pending_save = save_on_success;
        s_connecting = true;
        s_deadline_us = esp_timer_get_time() + (int64_t)PD_WIFI_CONNECT_MS * 1000;
        portENTER_CRITICAL(&s_status_lock);
        snprintf(s_status.sta_ssid, sizeof(s_status.sta_ssid), "%s", s_ssid);
        s_status.ip[0] = '\0';
        portEXIT_CRITICAL(&s_status_lock);
        pd_status_phase(PD_WIFI_STA_CONNECTING, 0);
    }
    return err;
}

static void pd_response_json(httpd_req_t *req, const char *json)
{
    httpd_resp_set_type(req, "application/json; charset=utf-8");
    httpd_resp_set_hdr(req, "Cache-Control", "no-store");
    httpd_resp_sendstr(req, json);
}

static esp_err_t pd_page_get(httpd_req_t *req)
{
    static const char html[] =
        "<!doctype html><html lang='fr'><head><meta charset='utf-8'>"
        "<meta name='viewport' content='width=device-width,initial-scale=1'>"
        "<title>PulseDeck - Wi-Fi</title>"
        "<style>body{font:16px system-ui;background:#111b29;color:#edf3fa;max-width:480px;margin:32px auto;padding:0 18px}"
        "input,select,button{box-sizing:border-box;width:100%;padding:12px;margin:7px 0 16px;font:inherit;border-radius:7px}"
        "button{background:#53a4dc;border:0;color:#071423;font-weight:bold}"
        "input[type=checkbox]{width:auto;margin:0;padding:0;flex:none;accent-color:#53a4dc}"
        ".password-toggle{display:flex;align-items:center;gap:10px;margin:-4px 0 16px;cursor:pointer}"
        "#result{white-space:pre-wrap}</style></head><body>"
        "<h2>PulseDeck : Wi-Fi</h2><p>Selectionnez un reseau 2,4 GHz, puis saisissez son mot de passe.</p>"
        "<form id='cfg'><label>Reseaux disponibles</label><select id='networks'><option>Recherche...</option></select>"
        "<button type='button' id='refresh'>Actualiser le scan</button>"
        "<label>SSID (modifiable, reseaux masques)</label><input id='ssid' maxlength='32' required autocomplete='off'>"
        "<label>Mot de passe Wi-Fi</label><input id='password' type='password' maxlength='63' autocomplete='off'>"
        "<label class='password-toggle'><input id='show-password' type='checkbox'>Afficher le mot de passe</label>"
        "<button type='submit'>Connexion</button></form><p id='result' role='status'></p>"
        "<script>const $=id=>document.getElementById(id);"
        "async function scan(){try{let r=await fetch('/api/networks',{cache:'no-store'});if(!r.ok)throw Error('Scan indisponible');"
        "let a=await r.json();let sel=$('networks');sel.replaceChildren();"
        "for(const n of a){let o=document.createElement('option');o.value=n.ssid;"
        "o.textContent=n.ssid+' ('+n.rssi+' dBm)'+(n.secure?' 🔒':'');sel.appendChild(o);}"
        "if(a.length)$('ssid').value=a[0].ssid;else $('result').textContent='Aucun SSID trouve';}"
        "catch(e){$('result').textContent=String(e)}}"
        "$('networks').onchange=()=>{$('ssid').value=$('networks').value};$('refresh').onclick=scan;"
        "$('show-password').onchange=()=>{$('password').type=$('show-password').checked?'text':'password'};"
        "$('cfg').onsubmit=async e=>{e.preventDefault();let p=new URLSearchParams({ssid:$('ssid').value,password:$('password').value});"
        "try{let r=await fetch('/api/connect',{method:'POST',headers:{'X-PD-Setup':'1','Content-Type':'application/x-www-form-urlencoded'},body:p});"
        "$('result').textContent=await r.text();}catch(e){$('result').textContent=String(e)}};"
        "async function status(){try{let s=await (await fetch('/api/status',{cache:'no-store'})).json();"
        "if(s.state==='online')$('result').textContent='Connecte : '+s.ip+' (le point d acces va se fermer)';"
        "else if(s.state==='ap'&&s.reason)$('result').textContent='Echec de connexion (code '+s.reason+'). Corrigez le mot de passe.';}"
        "catch(e){}}setInterval(status,2000);scan();</script></body></html>";
    httpd_resp_set_type(req, "text/html; charset=utf-8");
    httpd_resp_set_hdr(req, "Cache-Control", "no-store");
    httpd_resp_set_hdr(req, "X-Content-Type-Options", "nosniff");
    return httpd_resp_send(req, html, HTTPD_RESP_USE_STRLEN);
}

static esp_err_t pd_status_get(httpd_req_t *req)
{
    pd_wifi_status_t st;
    pd_wifi_status_get(&st);
    const char *state = st.phase == PD_WIFI_STA_ONLINE ? "online" :
                        st.phase == PD_WIFI_STA_CONNECTING ? "connecting" :
                        st.phase == PD_WIFI_AP_PORTAL ? "ap" : "error";
    char response[110];
    snprintf(response, sizeof(response), "{\"state\":\"%s\",\"reason\":%d,\"ip\":\"%s\"}", state,
             st.last_disconnect_reason, st.ip);
    pd_response_json(req, response);
    return ESP_OK;
}

/* Keep valid UTF-8 SSIDs and replace malformed octets to guarantee valid JSON. */
static void pd_json_ssid(const uint8_t *ssid, char *out, size_t max)
{
    size_t n = 0;
    for (size_t i = 0; i < 32 && ssid[i] && n + 3 < max;) {
        uint8_t c = ssid[i];
        if (c < 32 || c == 127) { out[n++] = '?'; i++; continue; }
        if (c == '"' || c == '\\') { out[n++] = '\\'; out[n++] = c; i++; continue; }
        if (c < 128) { out[n++] = c; i++; continue; }
        /* Keep valid UTF-8 names. Replace malformed bytes to preserve valid JSON. */
        size_t seq = (c >= 0xC2 && c <= 0xDF) ? 2 :
                     (c >= 0xE0 && c <= 0xEF) ? 3 :
                     (c >= 0xF0 && c <= 0xF4) ? 4 : 0;
        bool valid = seq && i + seq <= 32 && n + seq + 1 < max;
        if (valid) {
            for (size_t j = 1; j < seq; j++)
                if ((ssid[i+j] & 0xC0) != 0x80) valid = false;
            if (seq >= 3 && c == 0xE0 && ssid[i+1] < 0xA0) valid = false;
            if (seq >= 3 && c == 0xED && ssid[i+1] >= 0xA0) valid = false;
            if (seq == 4 && c == 0xF0 && ssid[i+1] < 0x90) valid = false;
            if (seq == 4 && c == 0xF4 && ssid[i+1] >= 0x90) valid = false;
        }
        if (!valid) { out[n++] = '?'; i++; continue; }
        for (size_t j = 0; j < seq; j++) out[n++] = ssid[i++];
    }
    out[n] = '\0';
}

static esp_err_t pd_http_unavailable(httpd_req_t *req, const char *message)
{
    httpd_resp_set_status(req, "503 Service Unavailable");
    httpd_resp_set_type(req, "text/plain; charset=utf-8");
    httpd_resp_sendstr(req, message);
    return ESP_FAIL;
}

static esp_err_t pd_networks_get(httpd_req_t *req)
{
    if (xSemaphoreTake(s_scan_lock, pdMS_TO_TICKS(1000)) != pdTRUE) {
        return pd_http_unavailable(req, "Radio busy");
    }
    pd_wifi_status_t st;
    pd_wifi_status_get(&st);
    if (st.phase != PD_WIFI_AP_PORTAL) {
        xSemaphoreGive(s_scan_lock);
        return pd_http_unavailable(req, "Provisioning unavailable");
    }
    wifi_scan_config_t scan = {0};
    esp_err_t err = esp_wifi_scan_start(&scan, true);
    if (err != ESP_OK) {
        xSemaphoreGive(s_scan_lock);
        return pd_http_unavailable(req, "Scan failed");
    }
    wifi_ap_record_t aps[PD_WIFI_SCAN_LIMIT];
    uint16_t found = PD_WIFI_SCAN_LIMIT;
    err = esp_wifi_scan_get_ap_records(&found, aps);  /* releases scan results */
    xSemaphoreGive(s_scan_lock);
    if (err != ESP_OK) {
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "Scan read failed");
        return ESP_FAIL;
    }
    httpd_resp_set_type(req, "application/json; charset=utf-8");
    httpd_resp_set_hdr(req, "Cache-Control", "no-store");
    httpd_resp_send_chunk(req, "[", 1);
    for (unsigned i = 0; i < found; ++i) {
        char escaped[70];
        pd_json_ssid(aps[i].ssid, escaped, sizeof(escaped));
        char item[150];
        snprintf(item, sizeof(item), "%s{\"ssid\":\"%s\",\"rssi\":%d,\"secure\":%s}",
                 i ? "," : "", escaped, aps[i].rssi,
                 aps[i].authmode == WIFI_AUTH_OPEN ? "false" : "true");
        httpd_resp_send_chunk(req, item, HTTPD_RESP_USE_STRLEN);
    }
    httpd_resp_send_chunk(req, "]", 1);
    httpd_resp_send_chunk(req, NULL, 0);
    return ESP_OK;
}

static int pd_unhex(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static bool pd_url_decode(const char *src, size_t len, char *dst, size_t cap)
{
    size_t j = 0;
    for (size_t i = 0; i < len; ++i) {
        unsigned char c = src[i];
        if (c == '%') {
            if (i + 2 >= len) return false;
            int a = pd_unhex(src[i+1]), b = pd_unhex(src[i+2]);
            if (a < 0 || b < 0) return false;
            c = (unsigned char)((a << 4) | b);
            i += 2;
        } else if (c == '+') c = ' ';
        if (c == 0 || c < 32 || c == 127 || j + 1 >= cap) return false;
        dst[j++] = c;
    }
    dst[j] = '\0';
    return true;
}

static bool pd_form_parse(const char *data, size_t len, char *ssid, char *password)
{
    bool have_ssid = false, have_password = false;
    for (size_t i = 0; i < len;) {
        size_t start = i;
        while (i < len && data[i] != '&') i++;
        const char *eq = memchr(data + start, '=', i - start);
        if (!eq) return false;
        size_t klen = (size_t)(eq - (data + start));
        if (klen == 4 && memcmp(data + start, "ssid", 4) == 0 && !have_ssid) {
            if (!pd_url_decode(eq + 1, i - (size_t)(eq + 1 - data), ssid, 33)) return false;
            have_ssid = true;
        } else if (klen == 8 && memcmp(data + start, "password", 8) == 0 && !have_password) {
            if (!pd_url_decode(eq + 1, i - (size_t)(eq + 1 - data), password, 65)) return false;
            have_password = true;
        } else return false;
        i++;
    }
    size_t sn = strlen(ssid), pn = strlen(password);
    return have_ssid && have_password && sn >= 1 && sn <= 32 && (pn == 0 || (pn >= 8 && pn <= 63));
}

static esp_err_t pd_connect_post(httpd_req_t *req)
{
    char header[8];
    if (httpd_req_get_hdr_value_str(req, "X-PD-Setup", header, sizeof(header)) != ESP_OK || strcmp(header, "1") != 0) {
        httpd_resp_send_err(req, HTTPD_403_FORBIDDEN, "Forbidden");
        return ESP_FAIL;
    }
    pd_wifi_status_t st;
    pd_wifi_status_get(&st);
    if (st.phase != PD_WIFI_AP_PORTAL) {
        return pd_http_unavailable(req, "Not in AP configuration mode");
    }
    if (req->content_len <= 0 || req->content_len > PD_WIFI_POST_MAX) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Invalid size");
        return ESP_FAIL;
    }
    char raw[PD_WIFI_POST_MAX + 1];
    size_t received = 0;
    while (received < (size_t)req->content_len) {
        int n = httpd_req_recv(req, raw + received, req->content_len - received);
        if (n <= 0) {
            httpd_resp_send_err(req, HTTPD_408_REQ_TIMEOUT, "Body read timeout");
            return ESP_FAIL;
        }
        received += (size_t)n;
    }
    raw[received] = '\0';
    if (strlen(raw) != received) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Malformed request");
        return ESP_FAIL;
    }
    pd_event_t ev = {.kind = PD_EVT_SUBMIT};
    if (!pd_form_parse(raw, received, ev.ssid, ev.password)) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "SSID/password invalid");
        return ESP_FAIL;
    }
    if (xQueueSend(s_events, &ev, 0) != pdTRUE) {
        return pd_http_unavailable(req, "Busy");
    }
    pd_response_json(req, "{\"status\":\"accepted\",\"message\":\"Connecting; AP remains active until success\"}");
    memset(&ev, 0, sizeof(ev));
    memset(raw, 0, sizeof(raw));
    return ESP_OK;
}

static esp_err_t pd_http_start(void)
{
    if (s_httpd) return ESP_OK;
    httpd_config_t config = HTTPD_DEFAULT_CONFIG();
    config.stack_size = 6144;
    config.lru_purge_enable = true;
    esp_err_t err = httpd_start(&s_httpd, &config);
    if (err != ESP_OK) return err;
    const httpd_uri_t endpoints[] = {
        {.uri="/", .method=HTTP_GET, .handler=pd_page_get},
        {.uri="/api/status", .method=HTTP_GET, .handler=pd_status_get},
        {.uri="/api/networks", .method=HTTP_GET, .handler=pd_networks_get},
        {.uri="/api/connect", .method=HTTP_POST, .handler=pd_connect_post},
    };
    for (unsigned i = 0; i < sizeof(endpoints)/sizeof(endpoints[0]); ++i) {
        err = httpd_register_uri_handler(s_httpd, &endpoints[i]);
        if (err != ESP_OK) {
            httpd_stop(s_httpd);
            s_httpd = NULL;
            return err;
        }
    }
    return ESP_OK;
}

static void pd_wifi_task(void *arg)
{
    (void)arg;
    esp_err_t err = nvs_flash_init();
    if (err != ESP_OK) goto fail; /* Never erase all NVS on startup. */
    bool saved = (pd_read_nvs() == ESP_OK);
    err = esp_netif_init();
    if (err != ESP_OK) goto fail;
    err = esp_event_loop_create_default();
    if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) goto fail;
    esp_netif_t *sta_netif = esp_netif_create_default_wifi_sta();
    if (!sta_netif || !esp_netif_create_default_wifi_ap()) {
        err = ESP_ERR_NO_MEM;
        goto fail;
    }
    /* Set the STA DHCP hostname before Wi-Fi starts / the first DHCP request.
       This is distinct from the provisioning AP SSID shown on the LCD. */
    err = esp_netif_set_hostname(sta_netif, PD_WIFI_STA_HOSTNAME);
    if (err != ESP_OK) goto fail;
    wifi_init_config_t init = WIFI_INIT_CONFIG_DEFAULT();
    err = esp_wifi_init(&init);
    if (err != ESP_OK) goto fail;
    err = esp_wifi_set_storage(WIFI_STORAGE_RAM); /* Only our explicit NVS commit stores STA credentials. */
    if (err != ESP_OK) goto fail;
    err = esp_event_handler_register(WIFI_EVENT, WIFI_EVENT_STA_DISCONNECTED, pd_driver_event, NULL);
    if (err != ESP_OK) goto fail;
    err = esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP, pd_driver_event, NULL);
    if (err != ESP_OK) goto fail;
    err = esp_wifi_set_mode(WIFI_MODE_STA);
    if (err != ESP_OK) goto fail;
    err = esp_wifi_start();
    if (err != ESP_OK) goto fail;
    /* Derive unique AP SSID from MAC; use the fixed WPA2 key requested. */
    pd_make_ap_credentials();
    if (saved) {
        s_attempts = 1;
        err = pd_sta_connect(false);
        if (err != ESP_OK) goto fail;
    } else {
        err = pd_ap_enable();
        if (err != ESP_OK) goto fail;
        err = pd_http_start();
        if (err != ESP_OK) goto fail;
    }
    while (true) {
        pd_event_t ev = {0};
        if (xQueueReceive(s_events, &ev, pdMS_TO_TICKS(250)) == pdTRUE) {
            if (ev.kind == PD_EVT_SUBMIT && s_ap_active && !s_connecting) {
                memcpy(s_ssid, ev.ssid, sizeof(s_ssid));
                memcpy(s_password, ev.password, sizeof(s_password));
                s_attempts = 1;
                if (pd_sta_connect(true) != ESP_OK) {
                    pd_status_phase(PD_WIFI_AP_PORTAL, -2);
                    s_connecting = false;
                }
            } else if (ev.kind == PD_EVT_DISCONNECT && (s_connecting || s_status.phase == PD_WIFI_STA_ONLINE)) {
                bool was_online = !s_connecting;
                s_connecting = false;
                if (was_online) s_attempts = 0;
                portENTER_CRITICAL(&s_status_lock);
                s_status.ip[0] = '\0';
                portEXIT_CRITICAL(&s_status_lock);
                pd_status_phase(s_ap_active ? PD_WIFI_AP_PORTAL : PD_WIFI_STA_CONNECTING, ev.reason);
                if (!s_ap_active && !pd_wifi_auth_error(ev.reason) && s_attempts < PD_WIFI_MAX_RETRIES) {
                    s_attempts++;
                    if (pd_sta_connect(false) == ESP_OK) continue;
                }
                if (pd_ap_enable() != ESP_OK || pd_http_start() != ESP_OK) {
                    ESP_LOGE(TAG, "Failed to start recovery AP");
                    pd_status_phase(PD_WIFI_ERROR, ev.reason);
                }
            } else if (ev.kind == PD_EVT_GOT_IP && s_connecting) {
                s_connecting = false;
                portENTER_CRITICAL(&s_status_lock);
                snprintf(s_status.ip, sizeof(s_status.ip), "%s", ev.ip);
                portEXIT_CRITICAL(&s_status_lock);
                if (s_pending_save) {
                    err = pd_save_nvs();
                    if (err != ESP_OK) {
                        ESP_LOGE(TAG, "NVS credentials commit failed: %s", esp_err_to_name(err));
                        pd_status_phase(PD_WIFI_AP_PORTAL, (int)err);
                        s_pending_save = false;
                        continue; /* Keep recovery AP, let user retry. */
                    }
                }
                s_pending_save = false;
                pd_status_phase(PD_WIFI_STA_ONLINE, 0);
                if (s_ap_active) {
                    /* Avoid stopping HTTPD from its own callback: worker owns lifecycle. */
                    if (s_httpd) { httpd_stop(s_httpd); s_httpd = NULL; }
                    err = esp_wifi_set_mode(WIFI_MODE_STA);
                    if (err == ESP_OK) s_ap_active = false;
                    else ESP_LOGE(TAG, "AP shutdown failed: %s", esp_err_to_name(err));
                }
            }
            memset(&ev, 0, sizeof(ev));
        }
        if (s_connecting && esp_timer_get_time() > s_deadline_us) {
            /* Fail closed into AP; ignore any ensuing disconnect event until next attempt. */
            s_connecting = false;
            esp_wifi_disconnect();
            pd_status_phase(PD_WIFI_AP_PORTAL, -3);
            if (pd_ap_enable() != ESP_OK || pd_http_start() != ESP_OK) {
                pd_status_phase(PD_WIFI_ERROR, -3);
            }
        }
    }
fail:
    ESP_LOGE(TAG, "Wi-Fi startup failed: %s", esp_err_to_name(err));
    pd_status_phase(PD_WIFI_ERROR, (int)err);
    vTaskDelete(NULL);
}

esp_err_t pd_wifi_start(void)
{
    if (s_events) return ESP_ERR_INVALID_STATE;
    s_events = xQueueCreate(PD_WIFI_QUEUE_SIZE, sizeof(pd_event_t));
    if (!s_events) return ESP_ERR_NO_MEM;
    s_scan_lock = xSemaphoreCreateMutex();
    if (!s_scan_lock) { vQueueDelete(s_events); s_events = NULL; return ESP_ERR_NO_MEM; }
    if (xTaskCreatePinnedToCore(pd_wifi_task, "pd_wifi", 8192, NULL, 4, NULL, 0) != pdPASS) {
        vQueueDelete(s_events);
        vSemaphoreDelete(s_scan_lock);
        s_events = NULL;
        s_scan_lock = NULL;
        return ESP_ERR_NO_MEM;
    }
    return ESP_OK;
}
