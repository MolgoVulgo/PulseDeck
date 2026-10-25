# PulseDeck — démarrage Wi-Fi / provisioning (`patch_0004`)

## Machine d'états

- `INIT -> STA_CONNECTING -> STA_ONLINE` avec des identifiants STA en NVS et une adresse IP obtenue.
- `INIT -> AP_PORTAL` sans identifiants NVS.
- `STA_CONNECTING -> AP_PORTAL` si erreur d'authentification, dépassement du délai ou échec des tentatives. Les identifiants enregistrés restent présents jusqu'à validation de nouvelles valeurs.
- `AP_PORTAL -> STA_CONNECTING` après soumission du portail : mode APSTA, AP maintenu pendant l'essai.
- `STA_CONNECTING -> STA_ONLINE` après IP et `nvs_commit` réussis, puis désactivation de l'AP.
- `STA_ONLINE -> STA_CONNECTING` sur perte de liaison ; trois tentatives maximum, puis AP de récupération.

Les callbacks Wi-Fi envoient des événements à un worker dédié. Ni NVS, ni HTTP, ni LVGL ne sont exécutés dans ces callbacks.

## Portail

- AP WPA2 `PulseDeck-XXXXXX`, mot de passe **fixe** `PulseDeck` (9 caractères, sensible à la casse). SSID et mot de passe présentés sur une bannière LVGL temporaire tant que le provisioning est actif.
- Connexion du téléphone à cet AP puis ouverture **manuelle** de `http://192.168.4.1/`.
- Scan des réseaux visibles 2,4 GHz avec RSSI, choix du SSID ou saisie manuelle d'un réseau masqué, mot de passe WPA2 personnel de 8–63 caractères ou mot de passe vide pour un réseau ouvert.
- Après un échec de mot de passe, l'AP reste actif et le portail accepte une nouvelle tentative. Le portail ne fournit pas de redirection DNS captive automatique.
- La case **Afficher le mot de passe** permet de basculer localement le champ STA entre masqué (par défaut) et visible. Elle ne change ni le mot de passe AP, ni la sauvegarde NVS, ni les données envoyées à `/api/connect`.

## Nom visible sur le réseau domestique

- Le nom d'hôte **DHCP de l'interface STA** est `PulseDesk`, positionné avec `esp_netif_set_hostname()` avant démarrage du Wi-Fi et avant la première demande DHCP, y compris si les identifiants STA existent déjà en NVS.
- Ne pas confondre ce nom d'hôte avec le **SSID AP de provisioning**, qui reste `PulseDeck-XXXXXX` avec la clé `PulseDeck`.
- La box peut conserver temporairement le nom précédent (`espressif`) dans sa liste d'appareils ou ajouter un suffixe à `PulseDesk` pour gérer les doublons : vérifier après reconnexion/redémarrage et renouvellement du bail DHCP. Le firmware ne modifie pas l'interface ou les alias propres à la box.

## NVS et confidentialité

- Namespace NVS `pd_wifi`, entrée binaire versionnée `sta_creds_v1` contenant la paire SSID/mot de passe ; pilote Wi-Fi en `WIFI_STORAGE_RAM` pour éviter toute persistance implicite.
- Sauvegarde uniquement après `IP_EVENT_STA_GOT_IP` ; l'échec du mot de passe candidat ne remplace pas les anciennes données NVS.
- Aucun mot de passe STA dans les réponses HTTP ni les logs. Le mot de passe AP n'est pas retourné via HTTP, seulement affiché localement.
- **Risque assumé :** la clé AP `PulseDeck` est publique, identique sur tous les appareils et ne protège pas contre un tiers à portée radio connaissant cette clé. Le portail HTTP de provisioning reste accessible à tout client connecté à cet AP ; éviter de laisser le mode AP actif inutilement.
- Le `sdkconfig` publié désactive le chiffrement NVS. Ce patch **ne prétend pas** chiffrer les identifiants au repos et ne touche pas au partitionnement ou au secure boot.
- Pas de serveur DNS de redirection, de portail HTTPS, de Wi-Fi 802.1X/Enterprise ni de passerelle Internet. Aucun mécanisme de suppression distante des identifiants n'est ajouté.
- Pour activer l'AP, la radio est stoppée puis configurée en APSTA/WPA2 avant redémarrage : aucun AP ne démarre volontairement avec la configuration par défaut.

## Intégration au Start

`pd_wifi_start()` est une fonction de startup non bloquante. `pd_wifi_status_get()` retourne une copie verrouillée de la phase, du code d'échec, du SSID STA, de l'IP et des informations AP. L'écran Start, actuellement non généré/actif dans l'export SquareLine publié, pourra interroger cette API depuis sa tâche LVGL.

Tant qu'il est désactivé, une simple bannière sur la couche supérieure des deux écrans actuels affiche la clé AP et l'adresse du portail ; elle disparaît après connexion STA. Aucune modification des sources SquareLine générées n'est nécessaire.

## Vérifications particulières du patch `patch_0004-2`

- Confirmer par `esp_netif_get_hostname()` (valeur `PulseDesk`) que le hostname de STA est appliqué avant la connexion, puis vérifier sur la box après reconnexion, sans effacer la NVS.
- Contrôler sur téléphone la case décochée au chargement (champ masqué), cochée (champ lisible), puis décochée (champ masqué), en vérifiant que la saisie reste intacte, et que `/api/connect` reçoit le même SSID/mot de passe.
- Le mot de passe WPA2 de l'AP reste `PulseDeck`, le SSID AP et les écrans LVGL sont inchangés.

## Validations demandées à Codex

1. Compiler sous ESP-IDF 5.5, sans installation de dépendance ; contrôler la taille des piles, la RAM interne et les allocations PSRAM.
2. NVS vide : AP sécurisé visible, clé LCD fonctionnelle, portail et scan SSID ; saisie du mot de passe puis connexion et enregistrement NVS.
3. Mot de passe invalide : vérifier code Wi-Fi, maintien AP et absence de commit NVS ; seconde tentative valide : NVS commit puis arrêt AP.
4. Reboot : connexion automatique avec identifiants conservés. Identifiants stockés volontairement incorrects : bascule AP. Coupure du routeur après ONLINE : tentatives bornées et reprise AP.
5. Examiner le mode APSTA sur le pilote local et vérifier la séquence radio stop -> configuration WPA2 -> start, sans AP temporairement ouvert.
6. Deux écrans LVGL, tactile et transitions inchangés, pas de ralentissement excessif ; surveiller plusieurs minutes, erreurs HTTP et scan en APSTA.
7. Rapporter les preuves minimales sans mots de passe, dans `diagnostics/patch_0004/`.

Ni compilation ESP-IDF, ni flash, ni test physique ne sont exécutés par ChatGPT Web.
