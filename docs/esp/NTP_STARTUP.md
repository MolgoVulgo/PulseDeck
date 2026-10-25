# PulseDeck — synchronisation NTP au démarrage (`patch_0005` et correctif `patch_0005-1`)

## Règles de temps et configuration

- Le protocole NTP renvoie une date/heure absolue référencée à **UTC**, indépendamment du pays où se situe le serveur.
- `PD_NTP_POOL_DEFAULT` = `pool.ntp.org` ; variable interne `s_ntp_pool[64]` dans `esp/main/pd_ntp.c` réservée à un futur paramétrage. Aucun formulaire, stockage NVS, setter ni changement dynamique du pool n'est implémenté.
- `PD_NTP_TZ_DEFAULT` = `UTC0` et `TZ=UTC0` via `setenv`/`tzset` ; pas de conversion locale ni heure d'été pour le moment.
- Intervalle SNTP **explicitement fixé à 3 600 000 ms (1 h)** dans `PD_NTP_RESYNC_INTERVAL_MS` et appliqué par `esp_sntp_set_sync_interval()` **avant** `esp_netif_sntp_init()`. Le `sdkconfig` publié vaut également 3 600 000 ms. Cet intervalle concerne les requêtes de correction réseau, jamais l'avancement de l'horloge locale. Une perte de Wi-Fi ne fige pas le temps ; sans réponse réseau, il peut dériver jusqu'à la prochaine correction.

## Démarrage et API pour Start

`app_main()` crée l'UI, lance `pd_wifi_start()` puis `pd_ntp_start()`. Les deux modules sont **asynchrones** ; NTP attend `PD_WIFI_STA_ONLINE` (IP obtenue) et n'arrête jamais l'UI.

API `pd_ntp.h` :

- `pd_ntp_status_get(&status)` : snapshot protégé, phase, pool et fuseau, erreur, dernier sync NTP et temps UTC courant (0 tant que non synchronisé).
- `pd_ntp_utc_now(&tm_utc)` : heure UTC en structure `tm` ; renvoie false tant qu'aucune réponse NTP valide n'a été reçue.
- Phases : `PD_NTP_WAIT_WIFI`, `PD_NTP_SYNCING`, `PD_NTP_SYNCED`, `PD_NTP_TIMEOUT`, `PD_NTP_ERROR`.
- `ever_synced` reste vrai après une coupure Wi-Fi : l'horloge locale continue, mais `phase` repasse à `WAIT_WIFI` durant la déconnexion. Le timestamp du dernier sync reste visible à l'écran Start.
- L'écran Start n'est ni activé ni recréé : les états sont disponibles pour son intégration future.

## Écran météo : date et heure

- Dans `esp/main/main.c`, un timer LVGL de 1 s vérifie l'horloge système via `pd_ntp_utc_now()`. L'écriture dans les widgets a lieu **uniquement si la minute UTC a changé** (ou au premier état disponible). Il n'exécute aucune requête NTP.
- `ui_meteo_hours` : `HH:MM` en UTC. `ui_meteo_date` : nom du jour, jour, mois et année en français, au format déjà utilisé dans SquareLine.
- Avant la **première** synchronisation effective : `--:--` et `Attente NTP`, au lieu des anciennes valeurs de démonstration. Si le Wi-Fi est perdu **après** la première synchronisation, les libellés continuent d'avancer grâce au temps système local.
- Si une nouvelle réponse SNTP décale l'horloge, les libellés reflètent cette correction au prochain tick LVGL ; changement de jour/mois/année compris. L'interface SquareLine générée et l'écran Start inactif restent intacts.

## Fiabilité

- SNTP utilise `esp_netif_sntp_init` d'ESP-IDF 5.5 et sa callback de synchronisation réelle. Une heure issue uniquement de `time()` au boot ne valide pas NTP.
- Au bout de **30 secondes de présence Wi-Fi en ligne** sans réponse : `PD_NTP_TIMEOUT`. Le client SNTP reste actif et peut confirmer une réponse tardive ; pas de redémarrage bloquant.
- Wi-Fi absent/portail AP : `PD_NTP_WAIT_WIFI`.
- Un redémarrage sans accès réseau ne réutilise pas une fausse date pour déclarer la synchronisation OK.
- L'appel de retour SNTP ne modifie jamais les objets LVGL ; un futur écran Start doit lire l'état depuis la tâche UI.

## Validation à réaliser par Codex / matériel

1. Contrôler le hash de la baseline indiquée, le manifeste et l'absence de suppression/déplacement ; compiler via ESP-IDF 5.5.
2. Flash sans effacer NVS, journaliser états Wi-Fi et NTP, observer une réponse NTP réelle et contrôler UTC avec `pd_ntp_utc_now()`.
3. Couper le Wi-Fi : vérifier `WAIT_WIFI` sans blocage UI ; rétablir la connexion et vérifier le fonctionnement ultérieur.
4. Tester boot sans identifiants / portail AP : état `WAIT_WIFI` et écran météo/monitor toujours réactifs.
5. Bloquer les réponses UDP/123 sur le réseau de test pour confirmer `TIMEOUT` au bout de 30 s et récupération si une réponse arrive ensuite.
6. Consigner durée de premier sync, mémoire interne libre, pile libre de la tâche, absence d'erreur ou de watchdog.

Ne pas prétendre qu'un test réseau réel ou une compilation ont été effectués côté Web.
