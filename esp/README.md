# PulseDeck ESP — phase 0 (squelette)

ESP-IDF natif + LVGL 9.5.0. Pas d'EEZ Studio, MQTT, Wi-Fi ou NTP a ce stade.

**Statut : non flashable fonctionnellement.** `display.c` et `touch.c` sont des gardes explicites retournant `ESP_ERR_NOT_SUPPORTED`. L'application refuse donc de rendre sans veritable driver RGB ST7701; le diagnostic LVGL est code mais inatteignable sur carte avant integration du driver. Aucun brochage ni timing n'a ete invente.

Donnees necessaires avant activation : version ESP-IDF retenue, referentiel exact du module ESP32-4848S040C_I, brochage RGB/ST7701, sequence d'initialisation, frequence pixel/timings, GPIO backlight, type/brochage/initialisation du tactile et politique de framebuffer PSRAM/DMA.

Cibles de verification **apres** integration materielle : amorcage, PSRAM, framebuffer 480x480, rendu LVGL, tactile, uptime/memoire, stabilite.

Reference de cablage candidate : https://github.com/NorthernMan54/ESP32-4848S040 (Arduino-GFX / GT911). Broches et timings listes dans PATCH_MANIFEST.md. Le portage ESP-IDF reste a realiser et a valider sur la variante C_I.
