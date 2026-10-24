# test_002-4-1 — Espressif Lottie Player, integration independante

> Archive : les dossiers temporaires de tests `esp/main/lottie_diag/` et `esp/main/lottie_assets/` ont été supprimés lors du nettoyage. Les commandes ci-dessous documentent les essais passés et ne sont plus exécutables depuis le dépôt actuel. Les sources restent consultables dans le commit Git `91e7efc`.

## Pourquoi un projet isole ?
Le composant `espressif/esp_lv_lottie_player` 0.1.0~1 et le widget `lv_lottie` natif de LVGL 9.5 exportent plusieurs symboles portant le meme nom. Les relier tous deux au firmware PulseDeck principal est incorrect. Le preparateur cree un projet ESP-IDF temporaire sous `/tmp/pulsedeck_external_lottie/` avec la partie d'affichage PulseDeck, les sources UI SquareLine copiees, et une seule implementation Lottie : Espressif. Les fichiers originaux ne sont jamais modifies.

## Versions figees dans le projet temporaire
- ESP-IDF: v5.5 existant (pas de nouvelle installation IDF)
- LVGL: `==9.5.0`
- `espressif/esp_lv_lottie_player`: `==0.1.0~1`
- `espressif/thorvg`: `==0.15.16`
- Autres composants d'affichage: versions deja annoncees dans `esp/main/idf_component.yml`
- JSON Meteocons `fill/clear-day.json`: 7302 octets, SHA-256 `930084453639864f519a4e2d2b791b042ac94b67816614144ff28e471106fc24`

Important : La premiere compilation peut devoir telecharger les deux nouveaux composants et leurs dependances transitives. Ne pas effectuer ce telechargement/installation sans autorisation explicite de l'utilisateur suivant AGENTS.md. Aucun composant, lockfile ni dependance ne doit etre installe dans le depot PulseDeck. La compilation du projet temporaire peut generer son propre `managed_components/` et `dependencies.lock` dans `/tmp` uniquement.

## API utilisee
- `lv_lottie_create(parent)` depuis `esp_lv_lottie.h` (et non le header du widget natif)
- `lv_lottie_set_buffer(obj, buf, w, h)`, argument buffer **en deuxieme** position
- JSON copie de la flash vers une zone **modifiable** allouee en PSRAM; `lv_lottie_set_src_data(obj, json_writable, len)`; conservation durant la lecture
- `lv_lottie_is_loaded`, `lv_lottie_set_loop_count(obj,-1)`, `lv_lottie_set_loop_enabled(obj,true)`, `lv_lottie_play`
- Pile UI 32768 octets et worker de chargement Espressif 32768 octets, y compris si stockee en PSRAM
- Buffer 64x64 ARGB8888 premultiplie 16384 octets PSRAM, memoire LVGL TLSF additionnelle 2 Mio PSRAM
- Lecture par defaut du composant, duree native 360 frames a 60 fps, **6 secondes** par cycle (non 72 s)

## Procedure Codex
1. Appliquer le ZIP via le mode patch et preflight. Les deux fichiers ajoutes doivent etre absents du depot; si deja presents et divergents, stopper et rapporter.
2. Preparation **sans telechargement ni build** depuis la racine du depot :

```sh
python3 esp/main/lottie_diag/prepare_espressif_player.py --mode full
```

3. Inspecter `/tmp/pulsedeck_external_lottie/full/main/idf_component.yml` et la copie `sdkconfig` (native `CONFIG_LV_USE_LOTTIE`, `CONFIG_LV_USE_THORVG`, `CONFIG_LV_USE_THORVG_INTERNAL` desactives). Si l'outillage manque de dependances, demander autorisation explicite; aucune installation automatique. A verifier aussi dans build final: aucune double definition de `lv_lottie_create` ni `tvg_*`.
4. Une fois les dependances autorisees/disponibles :

```sh
cd /tmp/pulsedeck_external_lottie/full
idf.py build
idf.py -p /dev/ttyUSB0 flash
idf.py -p /dev/ttyUSB0 monitor
```

5. Stopper immediatement au premier panic ou echec de configuration/compilation ; ne pas reparer opportunement. Sinon surveiller >=160 secondes et photographier/verifier visuellement le soleil, le disque central, les rayons et leur vitesse. Enregistrer les logs utiles et le SHA du binaire ELF.
6. **Option seulement si `full` echoue et sur instruction de l'utilisateur** : preparation independante du disque simplifie :

```sh
python3 esp/main/lottie_diag/prepare_espressif_player.py --mode b_reduced
```

Puis meme commande de build/flash/monitor depuis `/tmp/pulsedeck_external_lottie/b_reduced`. Ce mode ne montre que le disque central, pas un soleil complet. Il est un controle pour differencier les problemes de la composition et ceux de l'implementation Espressif.

Chaque preparateur refuse de remplacer un dossier de test deja cree. Ne pas supprimer un ancien dossier de travail sans consentement. Utiliser `--work-root /tmp/un-nouveau-repertoire` pour une nouvelle tentative.

## Rapport demande
Sous `diagnostics/patch_test_002-4-1/` : `report.md` et `serial-excerpt.log` (sans logs volumineux). Indiquer preparation, resolution des dependances, CMake/Kconfig final, compilation, taille firmware/partition, flash, premier temps chargement, `loaded`, total frames, frames courantes, cycles, RAM interne/PSRAM au demarrage, marges de pile, crash des deux CPU si present, validation visuelle (si fournie), limites. Presenter egalement l'etat final effectivement flashe (il peut etre instable), et preciser que la baseline n'a pas ete changee a part deux scripts ajoutes.

## References verifiees
- https://components.espressif.com/components/espressif/esp_lv_lottie_player/versions/0.1.0~1/readme
- https://github.com/espressif/esp-iot-solution/tree/12f6ca1182ec48889b17ec570fadaaf267cb336e/components/display/tools/esp_lv_lottie_player
- https://components.espressif.com/components/espressif/thorvg/versions/0.15.16/readme
