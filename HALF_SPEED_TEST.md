# Test `test_002-4-2` — Lecture Meteocons à moitié de vitesse

## But
Reprendre le player Espressif stable de `test_002-4-1` et le ralentir à **50 % de sa vitesse**. Taille inchangée 64×64, JSON original inchangé, pile UI 32 Kio et moteur externe Espressif inchangés.

- 360 images × 33 ms = 11,88 secondes par boucle (~12 s). Ce ralentissement est une vitesse de lecture, pas une baisse de fréquence d'affichage à 50 %.
- La variante de référence `test_002-4-1`, son code et son build `/tmp/pulsedeck_external_lottie/full` restent intacts.

## Instructions Codex
1. Appliquer mécaniquement le ZIP, vérifier les SHA et les deux scripts de référence comme prévu dans le manifeste. **Ne pas lancer de test avant ordre explicite.**
2. Vérifier le test d'insertion pure, sans aucun espace de travail :

   ```bash
   python3 esp/main/lottie_diag/prepare_half_speed.py --self-test
   ```

3. Préparer une nouvelle copie isolée, depuis le dépôt racine PulseDeck :

   ```bash
   python3 esp/main/lottie_diag/prepare_half_speed.py
   ```

   Le script crée `/tmp/pulsedeck_external_lottie_half_speed/full` et y injecte **une seule** modification C : `lv_lottie_set_frame_delay(obj, 33u);`. Il refuse une destination existante : ne pas supprimer/écraser sans demande explicite.
4. Seulement si l'utilisateur a autorisé build, flash et les dépendances éventuellement nécessaires, utiliser **uniquement** le workspace isolé :

   ```bash
   cd /tmp/pulsedeck_external_lottie_half_speed/full
   idf.py build
   idf.py -p /dev/ttyUSB0 flash
   idf.py -p /dev/ttyUSB0 monitor
   ```

   L'utilisation de Component Manager peut nécessiter des dépendances non présentes. Suivre les autorisations locales ; aucune installation automatique.
5. Arrêter le moniteur au premier panic, ou après **au moins 90 secondes** si stable ; collecter un extrait série utile. Vérifier le message `PLAYBACK_SPEED=50pct frame_delay_ms=33 expected_loop_ms=11880`, la progression des frames, les WRAPs, la pile UI et l'absence de redémarrage.
6. Sur écran : vérifier le soleil entier, la rotation des rayons **deux fois moins rapide** et la stabilité. Les WRAPs mesurés toutes les 5s peuvent être approximatifs ; noter le temps visuel d'une boucle si possible.
7. Documenter `diagnostics/patch_test_002-4-2/report.md` et `serial-excerpt.log`. Conserver les ELF/build uniquement sous /tmp ; ne pas synchroniser ces binaires, dépendances ou caches sur Drive. Pas de commit/push.

## Critères de succès
- Build/flash réussis, moteur Espressif seulement (Lottie natif désactivé) ; JSON original hashé conforme.
- Les 360 frames parcourues en ~12 secondes (±tolérance ordonnancement), plusieurs cycles sans watchdog.
- Image du soleil complète, taille 64×64 inchangée, ralentissement observé, pas de régression visuelle.

## Limites
Le script Python a été testé localement pour son insertion et sa syntaxe seulement. L'intégration à ESP-IDF, la durée réellement observée et le rendu sur écran restent à confirmer par Codex et l'utilisateur.
