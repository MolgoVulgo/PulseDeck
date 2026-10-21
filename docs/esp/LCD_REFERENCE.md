# PulseDeck — Référence LCD ESP32-4848S040C_I

Statut : **référence de configuration visuellement validée sur `esp-018`**, le 20 octobre 2026. Les paramètres électriques internes du panneau et la stabilité à long terme **ne sont pas certifiés par mesure**. Cette fiche ne demande aucun flash.

## Sources et précédence

1. Archive constructeur `4.0inch_ESP32-4848S040.zip`, sketch `1-Demo/Demo_Arduino/1_2_4.0_LvglWidgets/4.0_LvglWidgets.ino` et bibliothèque Arduino_GFX fournie (`st7701_type1_init_operations`).
2. Configuration effectivement appliquée dans PulseDeck `esp-018` et rapport `diagnostics/patch_0018/report.md` ; validation visuelle communiquée par l'utilisateur.
3. Références communautaires (comparaison seulement) : `sand1812/ESP32-4848S040`, `alaltitov/Guition-ESP32-S3-4848S040` et `NorthernMan54/ESP32-4848S040`.

**Politique :** ne pas substituer une table d'initialisation communautaire ou une table générique à `type1` sans identification de la dalle et analyse registre par registre. Ne pas confondre caractéristiques de l'exemple Arduino et valeurs effectives du pilote ESP-IDF.

## Plateforme

| Élément | Référence PulseDeck |
|---|---|
| Carte | ESP32-4848S040C_I / ESP32-S3 |
| Flash / PSRAM | 16 Mo flash / 8 Mo PSRAM octale |
| Firmware | ESP-IDF natif v5.5 ; LVGL 9.5.0 |
| Écran | ST7701(S), RGB parallèle 16 bits, 480 × 480 |
| Framebuffer LVGL | RGB565 (16 bits) ; ordre logique RGB |
| Tactile | GT911 |
| Alimentation de carte | 5 V (ne pas confondre avec les tensions analogiques internes de dalle) |

## Brochage de référence

| Signal | GPIO |
|---|---|
| ST7701 configuration SPI 3 fils : CS, SCK, SDA/MOSI | 39, 48, 47 |
| RGB DE, VSYNC, HSYNC, PCLK | 18, 17, 16, 21 |
| Rouge R0–R4 | 11, 12, 13, 14, 0 |
| Vert G0–G5 | 8, 20, 3, 46, 9, 10 |
| Bleu B0–B4 | 4, 5, 6, 7, 15 |
| Rétroéclairage (actif haut) | 38 |
| GT911 I²C SDA, SCL | 19, 45 |

Les broches de l'exemple doivent être comparées à la **variante matérielle physique** lors de tout remplacement de module. Les versions communautaires peuvent comporter des incohérences entre README et code source.

## Timings et format — `esp-018`

| Champ ESP-IDF | Valeur retenue | Statut |
|---|---|---|
| `pclk_hz` | `12000000` | Validé visuellement avec `esp-018` |
| `flags.pclk_active_neg` | `0` | Validé visuellement avec `esp-018` |
| `timings.hsync_front_porch` | `10` | Conforme à l'exemple constructeur |
| `timings.hsync_pulse_width` | `8` | Conforme à l'exemple constructeur |
| `timings.hsync_back_porch` | `50` | Conforme à l'exemple constructeur |
| `timings.vsync_front_porch` | `10` | Conforme à l'exemple constructeur |
| `timings.vsync_pulse_width` | `8` | Conforme à l'exemple constructeur |
| `timings.vsync_back_porch` | `20` | Conforme à l'exemple constructeur |
| `data_width` | `16` | RGB parallèle |
| `bits_per_pixel` | `16` | Framebuffer RGB565 |
| `num_fbs` | `1` | Implémentation `esp-018` |
| `bounce_buffer_size_px` | `4800` (10 lignes) | Implémentation `esp-018` |
| `flags.fb_in_psram` | `1` | Implémentation `esp-018` |
| Rotation de rendu | 90° horaire (incluant LVGL) | Référence d'orientation PulseDeck |

`gfx->begin(16000000)` dans l'exemple Arduino du constructeur **n'est pas une mesure de PCLK et ne se transpose pas aveuglément** au champ ESP-IDF. Le projet ESPHome alaltitov déclare 12 MHz et PCLK non inversée ; cela concorde avec la validation visuelle PulseDeck, mais ne certifie pas les caractéristiques analogiques du panneau.

## Initialisation ST7701 — à préserver

Utiliser les **35 entrées** de la table constructeur `st7701_type1_init_operations` déjà transposées dans `esp-018` : séquence intégrale, mêmes banques de registres, mêmes données et délais. Les réglages gamma et les commandes `E0` à `ED` ne doivent pas être reconstruits à partir du présent résumé ; la table source est l'autorité.

**Extrait des registres sensibles, en banque `0x11` :**

| Registre | Valeur |
|---|---|
| B0 (VOP) | `0x60` |
| B1 (VCOM) | `0x32` |
| B2 (VGH) | `0x07` |
| B3 | `0x80` |
| B5 (VGL) | `0x49` |
| B7 | `0x85` |
| B8 (AVDD/AVCL) | `0x21` |
| C1 | `0x78` |
| C2 | `0x78` |

Les libellés de tension sont indicatifs : **ce ne sont pas des tensions mesurées sur la carte**.

### Commande `0x3A` (COLMOD)

La table constructeur `type1` exécute `0x3A = 0x60` après le retour à la banque de registres principale. Son commentaire Arduino_GFX associe `0x60` au format RGB666. **Conserver cette commande et cette valeur** même si LVGL stocke ses pixels en RGB565 : les deux paramètres appartiennent à des couches différentes.

Avertissement connu dans le pilote ESP-IDF :

```text
W st7701_rgb: The 3Ah command has been used and will be overwritten by external initialization sequence
```

Le constructeur Arduino_GFX n'émet pas nécessairement ce même avertissement. Sa présence n'indique pas, seule, une anomalie ; ne pas supprimer `0x3A` pour rendre les logs silencieux. Si la version du pilote change, vérifier statiquement l'ordre effectif des écritures.

## Règles de sécurité et de validation

- Ne pas modifier les registres analogiques, gamma, inversion ou format ST7701 sans validation de compatibilité avec la dalle exacte.
- Ne pas modifier fréquence/polarité PCLK, timings, broches ou profondeur des pixels sans justification documentée et procédure de retour arrière.
- Préserver le firmware constructeur et `esp-018` comme références indépendantes ; **ne pas supposer que leurs moteurs graphiques sont identiques**.
- Désactiver les mires répétées/prolongées dans les firmwares d'utilisation normale ; surveiller les premiers essais, arrêter immédiatement en cas de rémanence, bandes nouvelles ou luminosité/couleurs anormales.
- Une validation visuelle ne remplace pas les essais de stabilité prolongée ni les mesures électriques. Le rapport `patch_0018` atteste compilation, flash et capture série courte, pas une qualification longue durée.
- Les réglages SPI effectifs, la fréquence PSRAM optimale et les autres polarités de signaux constructeur restent à qualifier ; ne pas inventer de valeurs à partir de ce document.

## Matrice de comparaison succincte

| Paramètre | Constructeur Arduino | sand1812 | alaltitov ESPHome | PulseDeck `esp-018` |
|---|---|---|---|---|
| ST7701 | `type1` | table explicite | préréglage `1` + 2 commandes | constructeur `type1` |
| PCLK | `gfx->begin(16000000)` (sémantique Arduino_GFX) | non explicitement fixé dans le sketch | 12 MHz | **12 MHz** |
| Polarité PCLK | nécessite lecture de l'implémentation | nécessite lecture de l'implémentation | non inversée | **non inversée** |
| H front/pulse/back | 10/8/50 | 10/8/50 | interne au composant ESPHome | **10/8/50** |
| V front/pulse/back | 10/8/20 | 10/8/20 | interne au composant ESPHome | **10/8/20** |
| `0x3A` | `0x60` | `0x60` | à établir depuis la séquence ESPHome effective | **`0x60`** |
| Broches GT911 SDA/SCL | 19/45 | 19/45 dans `touch.h` | 19/45 | **19/45** |

Révision : état de référence après validation visuelle d'`esp-018` ; toute évolution doit distinguer **documenté**, **testé visuellement**, **mesuré**, et **non vérifié**.
