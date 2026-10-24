# Lecteur Lottie Espressif — icônes météo PulseDeck

> Archive : les dossiers temporaires de tests `esp/main/lottie_diag/` et `esp/main/lottie_assets/` ont été supprimés lors du nettoyage. Les commandes ci-dessous documentent les essais passés et ne sont plus exécutables depuis le dépôt actuel. Les sources restent consultables dans le commit Git `91e7efc`.

Statut (23 octobre 2026) : **moteur de référence retenu**, **validé sur la carte dans un projet ESP-IDF isolé**, **pas encore intégré au firmware principal PulseDeck**. Cette fiche documente la configuration testée et les exigences de migration ; elle ne garantit pas une stabilité de plusieurs heures.

Version de référence anglaise : [`LOTTIE_ESPRESSIF.md`](LOTTIE_ESPRESSIF.md). Configuration matérielle associée : [`LCD_REFERENCE.md`](LCD_REFERENCE.md).

## 1. Décision et périmètre

- Utiliser **`espressif/esp_lv_lottie_player`**, avec **`espressif/thorvg` externe**, pour les icônes météo animées. Ne pas lier simultanément le lecteur Lottie natif de LVGL 9.5.0 et celui d'Espressif : ils exportent les mêmes symboles `lv_lottie_*`.
- Conserver le JSON Lottie Meteocons **original**, sans retirer de calque ni simplifier les formes de `clear-day`.
- Dans SquareLine, prévoir un **Panel/Container** qui délimite la zone météo. Créer le widget `lv_lottie` en code applicatif comme enfant du conteneur (ou l'aligner sur un placeholder exporté). `lv_lottie` **hérite déjà de `lv_canvas`** : un Canvas supplémentaire SquareLine n'est pas nécessaire. Ne pas modifier `esp/components/ui/generated/` ni les assets SquareLine d'origine.
- Cette décision fixe le **moteur cible** ; elle ne signifie pas que la migration du firmware principal a déjà été réalisée. Le montage fonctionnel se trouve actuellement dans un projet de test sous `/tmp`.

## 2. Configuration validée sur matériel

| Paramètre | Valeur observée dans les essais isolés |
| --- | --- |
| Carte / écran | ESP32-S3 / ESP32-4848S040C_I ; LCD 480 × 480 |
| ESP-IDF / LVGL | v5.5 / 9.5.0 |
| Lecteur Espressif | `espressif/esp_lv_lottie_player ==0.1.0~1` |
| ThorVG externe | `espressif/thorvg ==0.15.16` |
| Pile de la tâche UI | **32 768 octets** |
| Pile du worker de chargement | **32 Kio** (dans le composant) |
| Asset | `esp/ui/assets/meteocons/fill/clear-day.json` original (**7 302 octets**, SHA-256 `930084453639864f519a4e2d2b791b042ac94b67816614144ff28e471106fc24`) |
| Composition Lottie | 128 × 128, 360 frames à 60 FPS dans le JSON, deux couches |
| Sortie / buffer | 64 × 64, ARGB8888, **16 384 octets**, PSRAM alignée sur 64 octets |
| JSON fourni au lecteur | Copie PSRAM **modifiable**, conservée toute la vie du widget |
| Lottie / ThorVG natifs LVGL | Désactivés **dans le projet de test isolé** |
| Watchdog d'interruption | 300 ms, ni désactivé ni rallongé |
| Lecture d'origine | Cycle d'environ **6 secondes**, essai `test_002-4-1` |
| Lecture ralentie de 50 % | `lv_lottie_set_frame_delay(obj, 33u)` → **360 × 33 ms = 11,88 secondes**, essai `test_002-4-2` |

L'essai isolé enregistre également un pool LVGL distinct de 2 Mio en PSRAM. C'est une **caractéristique de ce montage testé**, pas une obligation de créer un nouveau pool pour chaque icône. Le plan mémoire du firmware principal devra être contrôlé lors de la migration.

## 3. Dépendances et isolation

Le projet de test a utilisé les versions suivantes :

```yaml
dependencies:
  lvgl/lvgl: "==9.5.0"
  espressif/esp_lv_lottie_player: "==0.1.0~1"
  espressif/thorvg: "==0.15.16"
```

Les composants nécessaires aux pilotes ST7701, GT911 et panneau LCD ont aussi été résolus. Il s'agit d'une **combinaison validée dans un projet séparé**, pas d'une autorisation d'installer des dépendances automatiquement. Le lockfile et les sources téléchargées sont restés dans `/tmp/pulsedeck_external_lottie/full` et `/tmp/pulsedeck_external_lottie_half_speed/full`. Aucun lockfile du dépôt principal n'a été modifié.

Pour la future intégration, **une seule implémentation Lottie/ThorVG doit être liée**. Désactiver le Lottie natif (`LV_USE_LOTTIE`) et ThorVG interne / les options vectorielles associées après audit de la configuration finale et des éventuels autres usages SVG. Dans les tests, ces options étaient désactivées **uniquement dans une copie de `sdkconfig`**. Vérifier dans la map du linker que `lv_lottie_create` et les autres fonctions proviennent de `espressif__esp_lv_lottie_player` et que ThorVG externe est utilisé. Conserver les pilotes d'affichage, l'export SquareLine et la configuration PSRAM tant qu'un changement distinct n'est pas nécessaire.

Une compilation isolée réussie n'est pas une migration réussie du firmware principal.

## 4. Créer une icône animée

Inclure `<esp_lv_lottie.h>`, `<esp_heap_caps.h>` et `<lvgl.h>`. **Séquence validée**, à exécuter dans la tâche LVGL ou sous son verrou approprié :

1. Allouer un buffer PSRAM **64 × 64 × 4 = 16 384 octets**, aligné sur 64 octets. L'essai utilise `heap_caps_aligned_alloc(64, 16384, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT)`.
2. Allouer `json_len + 1` octets en PSRAM modifiable, y copier **octet pour octet** le JSON d'origine et ajouter un `\0` final. **Ne jamais fournir directement un tableau `const` stocké en flash** : le parseur Espressif travaille sur une zone modifiable.
3. Créer `lv_lottie_create(parent_container)`, fixer taille et position, puis appeler `lv_lottie_set_buffer(obj, pixel_buf, 64, 64)`.
4. Appeler `lv_lottie_set_src_data(obj, json_copy, json_len)` et vérifier `lv_lottie_is_loaded(obj)` ainsi que `lv_lottie_get_total_frames(obj)` avant lecture.
5. Régler la boucle, la vitesse optionnelle, puis appeler `lv_lottie_play(obj)`.
6. Conserver **les deux allocations** aussi longtemps que le widget. Détruire le widget avant de libérer leurs stockages. Éviter de recréer le widget à chaque mise à jour météo ; changer d'animation avec une gestion explicite du cycle de vie.

Extrait — les variables `parent`, `pixels`, `json_copy` et `json_len` sont préalablement préparées selon les étapes ci-dessus :

```c
#include "lvgl.h"
#include "esp_lv_lottie.h"

lv_obj_t *obj = lv_lottie_create(parent);
lv_obj_set_size(obj, 64, 64);
lv_lottie_set_buffer(obj, pixels, 64, 64);
lv_lottie_set_src_data(obj, json_copy, json_len);
if (lv_lottie_is_loaded(obj)) {
    lv_lottie_set_loop_count(obj, -1);
    lv_lottie_set_loop_enabled(obj, true);
    lv_lottie_set_frame_delay(obj, 33u);  /* option : vitesse ~50 % */
    lv_lottie_play(obj);
}
```

Sur l'écran SquareLine actuellement testé, le lecteur a été créé comme **frère** de `ui_test_Image1`, aligné sur ce placeholder, puis le placeholder a été masqué après chargement réussi. Pour de nouveaux écrans, préférer un conteneur nommé comme parent. Toutes les manipulations LVGL doivent respecter le contexte d'exécution/verrouillage du firmware.

## 5. Modifier la vitesse

L'API Espressif `lv_lottie_set_frame_delay(obj, delay_ms)` remplace la durée par frame issue du JSON et redémarre la chronologie lorsque l'animation est chargée. Appliquer ce réglage **après le chargement** et **avant `lv_lottie_play`** pour éviter un redémarrage visuellement perceptible.

| Délai | Durée approximative pour 360 frames | Effet |
| --- | --- | --- |
| `0` | environ 6 s (durée JSON) | Retour à la vitesse d'origine ; ne signifie pas 0 ms/frame |
| `20` ms | 7,20 s | Légèrement ralentie |
| `25` ms | 9,00 s | Modérée |
| **`33` ms** | **11,88 s** | **Vitesse 50 % testée dans `test_002-4-2`** |
| `40` ms | 14,40 s | Plus lente |

Ces durées sont celles de la **chronologie de l'animation**, pas des FPS de rendu réellement mesurés. Les performances dépendent de la charge et de la planification LVGL. Avec 33 ms, la cadence logique est d'environ 30,3 frames/s. Ce réglage est **validé techniquement sur ce test**, mais la préférence finale pour les autres icônes reste à décider. Le JSON Meteocons n'a pas besoin d'être modifié pour ralentir.

## 6. Reproduire les essais isolés (Codex)

Depuis le dépôt PulseDeck avec l'environnement ESP-IDF déjà disponible :

```sh
python3 esp/main/lottie_diag/prepare_espressif_player.py --mode full
# Produit /tmp/pulsedeck_external_lottie/full ; pas de téléchargement, build ni flash

python3 esp/main/lottie_diag/prepare_half_speed.py
# Produit /tmp/pulsedeck_external_lottie_half_speed/full ; référence conservée
```

Chaque dossier de test possède ses copies sources et son `sdkconfig` temporaire. Inspecter `idf_component.yml`, le port de la carte et le Kconfig final avant `idf.py build`, `flash` ou `monitor`. Tout téléchargement de dépendances nécessite une autorisation explicite selon les règles projet. Les préparateurs refusent d'écraser un dossier existant ; ne pas le supprimer/nettoyer implicitement.

Les preuves sont sur Drive, dans des diagnostics **hors baseline source** : `diagnostics/patch_test_002-4-1/report.md` (JSON original, 30–35 s, six boucles, confirmation visuelle utilisateur) et `diagnostics/patch_test_002-4-2/report.md` (33 ms, 40 s, trois boucles, sans panic). L'intégrité du heap après chargement, l'absence de fuite sur plusieurs heures et l'intégration permanente ne sont **pas encore validées**. Refaire une campagne de validation après migration dans le firmware principal (mémoire, fluidité UI, orientation, changement d'icône).

## 7. Sources et compatibilité

- [Composant Espressif officiel](https://components.espressif.com/components/espressif/esp_lv_lottie_player/versions/0.1.0~1/readme)
- [En-tête du lecteur examiné](https://github.com/espressif/esp-iot-solution/blob/12f6ca1182ec48889b17ec570fadaaf267cb336e/components/display/tools/esp_lv_lottie_player/include/esp_lv_lottie.h)
- [Implémentation Espressif examinée](https://github.com/espressif/esp-iot-solution/blob/12f6ca1182ec48889b17ec570fadaaf267cb336e/components/display/tools/esp_lv_lottie_player/src/lv_lottie.c)
