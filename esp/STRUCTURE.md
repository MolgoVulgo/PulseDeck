# Structure ESP-IDF / SquareLine - PulseDeck

- `main/` : firmware ESP-IDF, initialisation materielle et runtime LVGL existants.
- `components/ui/CMakeLists.txt` : composant ESP-IDF `ui`, maintenu a la main.
- `components/ui/generated/` : **export SquareLine remplaçable** (`ui.c`, `screens/`, `fonts/`, `filelist.txt`, CMake genere ...).
- `ui/` : projet SquareLine editable (`SquareLine_Project.spj`, `.slp`, assets). Ne pas confondre avec l'export.

## Export

Dans SquareLine Studio, paramétrer **Export UI Files** sur :

`/home/kaj/Projets/PulseDeck/esp/components/ui/generated/`

Le `.slp` contient ce chemin, mais le profil OBP local (hors depot) peut proposer un autre defaut : controler l'ecran d'export.

Ne jamais modifier les fichiers dans `generated/` pour y placer du code metier ou
un CMake ESP-IDF. Le `CMakeLists.txt` produit par SquareLine dans `generated/`
reste un artefact d'export et n'est pas execute par ESP-IDF.

Le CMake parent charge `generated/filelist.txt` pour compiler les sources C exportees.
Lorsqu'un ecran ou un asset modifie la liste des sources, relancer `idf.py build` ;
si besoin `idf.py reconfigure` sans `fullclean`.

La structure ne change pas l'ecran lance par `main.c`. L'appel a `ui_init()`
reste une integration applicative distincte, a realiser apres validations.

## Limite identifiee avant le patch

L'export SquareLine actuel contient `#include "lv_i18n.h"` dans `ui.h`,
mais aucun `lv_i18n.h` n'apparait dans la baseline publiee. Le projet
SquareLine active le multilangue. Ne pas inventer un stub ou supprimer
l'inclusion a la main : verifier si l'en-tete est fourni par une
composante externe disponible localement et, sinon, corriger la generation
SquareLine lors d'un correctif distinct. L'absence peut bloquer la compilation.
