# Diagnostic patch_0001 ESP

Date locale: 2026-10-08

## Patch
- Source Drive: `esp/patch_0001.zip`
- Fichier local temporaire: `/tmp/pulsedeck_patch_esp_0001/patch_0001.zip`
- Application: creations sous `esp/` uniquement
- Controle de contenu: 14 fichiers `esp/` verifies par SHA-256 entre ZIP et depot
- `DELETE_FILES.txt`: aucune suppression
- `MOVE_FILES.txt`: aucun deplacement

## Environnement ESP-IDF local
- `idf.py` absent du PATH initial
- Export tente: `/home/kaj/.platformio/packages/framework-espidf/export.sh`
- Version framework ESP-IDF locale lue: `5.5.0`
- Echec export/build: environnement Python ESP-IDF manquant

Erreur utile:

```text
ERROR: ESP-IDF Python virtual environment "/home/kaj/.espressif/python_env/idf5.5_py3.14_env/bin/python" not found.
zsh:1: command not found: idf.py
```

## PlatformIO
- Commande tentee: `pio run -d esp`
- Resultat: echec, `esp/` n'est pas un projet PlatformIO car aucun `platformio.ini` n'est fourni par le patch.

Erreur utile:

```text
NotPlatformIOProjectError: Not a PlatformIO project. `platformio.ini` file has not been found in current working directory (/home/kaj/Projets/PulseDeck/esp).
```

## Flash / monitor
- Non executes: aucun firmware n'a ete produit.
- Blocage attendu cote patch: `display.c` retourne volontairement `ESP_ERR_NOT_SUPPORTED`; le manifeste indique que le patch n'est pas declare compilable ni operationnel materiellement avant integration du driver RGB/ST7701 et tactile.
