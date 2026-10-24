# PulseDeck ESP — bring-up 002

Cible: ESP32-S3, ESP-IDF **v5.5**, LVGL **9.5.0**. Le projet est un projet **ESP-IDF natif**, pas PlatformIO.

Le test `test_002` embarque `esp/ui/assets/meteocons/fill/clear-day.json` depuis les assets locaux (Meteocons Lottie 0.1.0), sans téléchargement au build. Ces assets sont exclus de Git et Drive et doivent être présents sur le poste de compilation. Le profil ESP-IDF `CONFIG_PARTITION_TABLE_SINGLE_APP_LARGE` réserve 1500 Kio à l'application pour accueillir Lottie/ThorVG ; NVS, PHY et l'offset de l'application restent ceux du profil single-app précédent. Ce profil ne fournit pas d'OTA.

## Lecteur Lottie météo retenu

Le moteur de référence pour les icônes animées est **Espressif `esp_lv_lottie_player` + ThorVG externe**, validé sur ESP32-S3 dans les essais isolés `test_002-4-1` (JSON Meteocons complet à sa vitesse d'origine) et `test_002-4-2` (lecture à 50 % : 33 ms/frame). La migration dans le **firmware principal n'est pas encore réalisée** : ne pas confondre les builds de diagnostic sous `/tmp` et `idf.py build` depuis ce dossier.

Guide d'architecture, dépendances, mémoire, SquareLine/Canvas, API de lecture et tests : [`../docs/esp/LOTTIE_ESPRESSIF.fr.md`](../docs/esp/LOTTIE_ESPRESSIF.fr.md) (EN : [`../docs/esp/LOTTIE_ESPRESSIF.md`](../docs/esp/LOTTIE_ESPRESSIF.md)). Les essais Lottie natifs documentés ci-dessus restent historiques.

## Compiler sur le poste local (Codex)

```sh
cd /home/kaj/Projets/PulseDeck/esp
pyenv shell 3.12.15    # dans un shell ou pyenv init est actif
. /home/kaj/esp/esp-idf/export.sh
idf.py --version       # attendu : ESP-IDF v5.5
python --version       # attendu : Python 3.12.15
idf.py set-target esp32s3  # initialisation une fois; modifie sdkconfig
idf.py build
```

**Ne pas** lancer `pio run -d esp`, ni exporter l'ESP-IDF de `.platformio/packages`. Ne pas lancer `idf.py fullclean` ou de mise a jour automatique des dependances sans accord. Si `pyenv shell` n'est pas disponible, utiliser `eval "$(pyenv init - zsh)"` puis reessayer dans ce shell.

La resolution des composants LVGL/ST7701/GT911 par le gestionnaire ESP-IDF est necessaire lors de la premiere compilation; signaler un echec reseau ou de version, ne pas remplacer arbitrairement les versions.

Le parametre PSRAM `CONFIG_SPIRAM_MODE_OCT` est une **hypothese** de la variante; verifier la variante/flash/PSRAM avant tout flash. Si la carte est QSPI, adapter proprement le menuconfig avec preuve materielle, pas au hasard. Les broches et timings proviennent de NorthernMan54, pas d'une validation physique sur cette carte exacte.

## Premier essai

1. Brancher la carte et relever le port serie par `/dev/serial/by-id/` ou `ls /dev/ttyACM* /dev/ttyUSB*`.
2. `idf.py -p PORT flash monitor` **uniquement apres compilation reussie et confirmation carte/port**.
3. Relever les logs de boot, les erreurs LCD/tactile, la couleur, l'orientation, la stabilite et la memoire.
4. Retourner un diagnostic sous `diagnostics/esp_002/report.md` avec version, commande, statut, erreurs et traces pertinentes (sans secrets).

Le rendu RGB avec copies de surfaces partielles vers framebuffer en PSRAM constitue une implementation initiale non optimisee; performance et absence de tearing a mesurer. Le GT911 n'est pas bloquant si son initialisation echoue.
