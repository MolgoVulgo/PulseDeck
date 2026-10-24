# Bilan des essais d’affichage PulseDeck — clôture du 24 octobre 2026

## Portée et décision

Campagne d’essais sur ESP32-S3, écran 480×480, ESP-IDF 5.5, LVGL 9.5, ThorVG et PSRAM 8 Mio. Les tests ont exploré SVG, Lottie, animation à 50 %, sept instances simultanées, placement des tâches sur les cœurs, profilage, rendu ThorVG autonome et concurrence. Les informations ci-dessous proviennent des rapports de la campagne et des diagnostics interprétés durant les essais. Lorsqu'une mesure n'est pas disponible ou non validée sur l'écran, elle n'est pas extrapolée.

**Décision de clôture :** abandon du parallélisme ThorVG et du banc des sept Lottie; conserver le socle LVGL, le tactile, les écrans SquareLine, les valeurs ESP et la navigation. Pour la future interface météo, retenir comme orientation une seule animation météo principale et des icônes de prévision statiques, sans les intégrer tant que les UI définitives ne sont pas livrées.

## Chronologie et conclusions par essais

| Essais | Sujet | Résultat et limites |
|---|---|---|
| test_001, variantes 001-1 à 001-3 | Affichage expérimental SVG / initialisation mémoire | SVG et chemin vectoriel explorés; mise en place d’un pool LVGL en PSRAM pour les besoins du rendu. Pas de baseline métier à en déduire. |
| test_002 à test_002-4-14 | Lottie/ThorVG, assets et variantes | Expérimentations de lecture/rendu et de garde-fous de mémoire. Résultats détaillés conservés dans leurs rapports diagnostics; pas de conclusion quantitative unique applicable à la future UI. |
| test_002-5 à 002-5-4-1 | Sept animations et profil de lecture | Sept objets de 64×64, JSON Meteocons d'origine, fr=60 et vitesse 50 %; essais de charge. |
| test_002-5-5 | Sept Lottie sur CPU0 à 160 MHz | Temps de handler d’environ 277 ms en charge. |
| test_002-5-6 | UI/LVGL sur CPU1 | Environ 273 ms, faible différence au regard de la charge totale. |
| test_002-5-7 | Analyse du flush LCD | Le flush ne représentait qu’environ 2,84 % du temps mesuré; le rendu domine. |
| test_002-5-8 | Profil statique vs animé | Charge majeure associée à l'animation; les résultats ne justifient pas de garder sept objets Lottie figés en production. |
| test_002-5-9 | Progression des frames | Saut moyen d'environ 8,44 indices par handler; fréquence effective de rendu autour de 3,6 Hz dans le profil lourd, et non les 30 fps théoriques. |
| test_002-5-10 | Callback Lottie | Environ 82,5 % du temps total du handler, ~234 ms pour sept callbacks. |
| test_002-5-11 | Fréquence CPU 240 MHz | Fréquence confirmée; handler ~229,829 ms; callbacks ~187,092 ms. |
| test_002-5-12 | UI CPU0 / callbacks délégués séquentiellement CPU1 | Handler ~217,671 ms; coût de transfert ~0,44 ms, mais aucun calcul parallèle des sept animations. |
| test_002-5-13 | Audit de faisabilité du parallélisme | LVGL 9.5 / ThorVG 0.15.3, pool builtin TLSF et LV_OS_NONE; états partagés non sûrs sans protections. |
| test_002-5-14 à 14-2 | Première sonde autonome | Corrections de configuration et cas `tvg_animation_set_frame(0)`; pas encore de parallélisme valide. |
| test_002-5-14-3 | Un worker ThorVG autonome | Trois frames rendues (indices 0/15/30), temps observés 2,929 / 29,087 / 25,057 ms. Un worker viable; ne prouve pas l'exécution sûre en parallèle. |
| test_002-5-15 | Deux workers simultanés CPU0/CPU1 | Watchdog pendant le chemin `lv_realloc` / TLSF; aucun rendu parallèle terminé ni gain mesuré. |
| test_002-5-16 | Activation LVGL FreeRTOS | Échec compilation : LV_DRAW_THREAD_STACK_SIZE 8192 < 32768 requis par LVGL avec ThorVG. |
| test_002-5-16-1 | Pile de rendu 32 Kio | Build/flash réussis, mutex TLSF présent au binaire; création du second worker échouée, puis boucle de redémarrage. Concurrence non testée. |
| test_002-5-17 | Retour au chemin séquentiel test11 | Build/flash réussis, sept objets Lottie chargés, pas de watchdog observé pendant ~80 s. Gestes déclarés mais non validés matériellement. |
| test_002-5-18 | Réactivation des métriques et propagation des gestes | Code intégré; l’existence des handlers ne suffit pas à prouver la navigation physique. Consulter le diagnostic individuel pour le test réel. |
| test_002-5-19 | Trois animés / quatre figés | Configuration logicielle préparée; première frame statique des quatre objets, sans supprimer leur instance Lottie. |
| test_002-5-20 | Mesures mémoire | Build/flash réussis, profil 3 animés / 4 figés, ~110 s sans crash, écran ESP seulement. Les chiffres détaillés suivent. |

## Mémoire — test_002-5-20

| Phase | RAM interne libre (octets) | Plus grand bloc RAM (octets) | PSRAM libre (octets) | Plus grand bloc PSRAM (octets) | Marge pile UI (octets) |
|---|---:|---:|---:|---:|---:|
| Après `ui_init` | 161707 | 81920 | 5826540 | 5767168 | 29908 |
| Après démarrage métriques | 161487 | 81920 | 5826416 | 5767168 | 29908 |
| Après sept objets Lottie | 32047 | 31744 | 5675956 | 5636096 | 11700 |
| Régime stabilisé | **27199** | **26624** | **5675956** | **5636096** | **11700** |

Capacités rapportées : RAM interne 345731 octets, PSRAM 8388608 octets. Utilisation stabilisée ≈92,1 % RAM interne, ≈32,3 % PSRAM. Entre les phases « métriques » et « sept Lottie », le libre baisse de 129440 octets en interne et de 150460 octets en PSRAM; ces deltas incluent toutes les opérations intermédiaires. **Ils ne sont pas des coûts unitaires Lottie.** Le pool LVGL de 2 Mio était déjà réservé avant les photographies et ses allocations TLSF internes ne sont pas mesurées par `heap_caps`.

Toutes les photographies ont `screen=esp`. Aucune mesure inter-écrans ni validation tactile matérielle n'est incluse. Les 110 s sans incident ne prouvent pas une stabilité multi-heures.

## Contraintes retenues pour l'interface finale

- Ne jamais réintroduire le banc de sept animations, les workers parallèles, leurs sondes, leurs profils de performance, ou les tâches périodiques artificielles dans le firmware standard.
- Préserver l'unique tâche UI, l'initialisation écran et tactile, le pool LVGL PSRAM, l'actualisation des valeurs ESP32 et les événements de navigation générés.
- Laisser les prochains écrans et visuels météo à la définition des UI finales; aucun nouvel élément météo n'est créé dans le patch de nettoyage.
- Mesurer les marges RAM interne et plus grand bloc lors d'ajouts UI ultérieurs; ne pas considérer la PSRAM comme substitut automatique de toutes les allocations DMA ou piles.
- Les sondes autonomes et les rapports sont historiques, pas du code de production.

## Sources et limites

Rapports Codex : `diagnostics/patch_test_001*`, `diagnostics/patch_test_002*`, particulièrement `patch_test_002-5-5` à `patch_test_002-5-20`. Les valeurs numériques ci-dessus proviennent des rapports individuels et du diagnostic mémoire final. Le code de production après nettoyage n'a pas été compilé ni flashé par ChatGPT; la validation matérielle doit être exécutée localement.
