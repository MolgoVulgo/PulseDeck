# PulseDeck ESP — partition applicative 16 Mo et logs MQTT (patch_0008)

## Cause du problème

`esp/sdkconfig` déclarait déjà `CONFIG_ESPTOOLPY_FLASHSIZE_16MB=y`, mais
`CONFIG_PARTITION_TABLE_SINGLE_APP_LARGE=y` choisissait la table standard
ESP-IDF 5.5 : partition `factory` de **1 500 Kio**. La taille totale de la
flash ne détermine pas automatiquement la taille des partitions.

## Nouvelle table `esp/partitions.csv`

| Nom | Type | Offset | Taille | Fin exclusive |
| --- | --- | ---: | ---: | ---: |
| nvs | data/nvs | 0x9000 | 0x6000 | 0xF000 |
| phy_init | data/phy | 0xF000 | 0x1000 | 0x10000 |
| factory | app/factory | 0x10000 | 0x800000 (8 Mio) | 0x810000 |

La table commence à `CONFIG_PARTITION_TABLE_OFFSET=0x8000` (inchangé).
La région supérieure `0x810000..0xFFFFFF` reste non affectée, réservée à
l'évolution future (pas un système de fichiers utilisable aujourd'hui).
La table ne crée **aucun slot OTA** : l'ancien mode de flash USB est conservé.
Les trois offsets existants sont conservés, afin d'éviter une migration des
identifiants Wi-Fi NVS. Aucun effacement de NVS n'est demandé.

`esp/sdkconfig` **et** `esp/sdkconfig.defaults` sélectionnent désormais
`CONFIG_PARTITION_TABLE_CUSTOM=y`, nom `partitions.csv`; la taille flash
reste `16MB`.

## Prérequis à vérifier avant le flash

- **Lire la taille physique de flash détectée sur la carte** (16 Mio attendus) :
  inspection `esptool flash_id` / équivalent de la version installée, ou
  un relevé fiable du module flash. Si la capacité n'est pas confirmée à
  au moins **0x810000 octets**, **ne pas flasher** la nouvelle table ;
  consigner la mesure dans le diagnostic. L'information de `sdkconfig`
  est un *paramétrage*, pas une mesure physique.
- Conserver la connexion USB et éviter toute coupure d'alimentation pendant
  la mise à jour de la table et de l'image applicative.
- Ne pas utiliser `erase_flash`, `erase-flash`, `nvs_flash_erase` ni
  `idf.py fullclean` comme remède automatique. Conserver les identifiants NVS.

## Contrôles Codex (ESP-IDF 5.5)

1. Comparer l'ancienne table (`nvs=0x9000/0x6000`,
   `phy_init=0xF000/0x1000`, `factory=0x10000/1500K`) à la table générée.
2. Mesurer flash physique ; vérifier 16 Mio avant toute écriture et appliquer
   uniquement si conforme.
3. Exécuter `idf.py partition-table`, `idf.py build` ; comparer le tableau
   final et l'espace applicatif disponible ; vérifier `git diff --check`.
4. Exécuter `idf.py -p /dev/ttyUSB0 flash` **sans effacement NVS**, puis
   `idf.py -p /dev/ttyUSB0 monitor` avec une durée bornée.
5. Vérifier redémarrage, reprise Wi-Fi sans provisionnement, NTP, MQTT,
   navigation et heure; laisser l'écran Monitoring en place.
6. Tester la connexion MQTT réelle ou noter l'absence de preuve si le broker
   est indisponible. Le journal doit montrer `MQTT_EVENT_CONNECTED` seulement
   si un CONNACK valide a été reçu, `MQTT_EVENT_DISCONNECTED` lors d'une
   coupure observable, ou `MQTT_EVENT_ERROR` avec le code si disponible.
   Le message `MQTT client started` prouve uniquement le démarrage local.
7. Publier `diagnostics/patch_0008/report.md` et un extrait expurgé
   (sans identifiants Wi-Fi, secrets ou adresses clients privées).

## Limites

Les contrôles Web valident la configuration statique et le contrat des API,
mais ne prouvent ni la capacité physique du module, ni la compilation réelle
ESP-IDF, ni les événements du broker. Les événements seront journalisés dans
le callback MQTT **hors section critique** ; le niveau log global INFO est
déjà actif. Pas de souscriptions ni de publications ajoutées.
