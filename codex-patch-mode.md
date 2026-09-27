# Codex — application mécanique de patch ZIP — V2.1

> Réservé à Codex lorsqu'un patch ZIP complet existe déjà.

## Rôle
`inspecter -> contrôler -> appliquer exactement -> vérifier -> valider -> diagnostiquer -> rapporter`

Priorité : utilisateur > `AGENTS.md`/règles locales > présent document > documentation technique. Les règles Web ne sont pas une autorité locale. Le manifeste définit le périmètre sans contourner les garde-fous locaux.

## Base et transport
Dépôt local = source de vérité locale/cible. ZIP ciblé = source du correctif. Drive = transport. Jamais de sync Drive -> dépôt. Récupérer seulement le patch demandé sous `/tmp`. Git reste indépendant.

Si l'utilisateur annonce un patch disponible sans fournir de chemin local, lire `REMOTE` et `PATCH_DIR` depuis `sync-drive.conf`, utiliser `${REMOTE}/${PATCH_DIR}/` comme emplacement distant des patchs, lister uniquement ce répertoire distant pour identifier le patch demandé, puis récupérer uniquement le ZIP ciblé avec `rclone` vers un emplacement temporaire sous `/tmp`. Ne jamais chercher, créer ou exiger un dossier `patch/` local. Une fois le ZIP récupéré sous `/tmp`, poursuivre normalement le présent protocole.

## Préflight
Identifier la racine ; inspecter l'archive ; lire `PATCH_MANIFEST.md`, `DELETE_FILES.txt`, `MOVE_FILES.txt` ; relever Git si disponible ; distinguer les changements préexistants. Refuser chemins absolus, `..`, sorties de racine, symlinks/liens dangereux, entrées spéciales, doublons conflictuels, ambiguïtés de casse, secrets et artefacts interdits.

`PATCH_MANIFEST.md` est obligatoire. DELETE/MOVE sont normalement présents ; leur absence doit être explicitement justifiée par le manifeste.

## Application
Ordre : DELETE -> MOVE -> créations/remplacements -> permissions -> vérification. Ne créer/modifier que ce que le ZIP fournit et annonce. Aucune modification auxiliaire ou fusion implicite.

## Vérification
Contrôler présence et contenu/hash des fichiers livrés, DELETE/MOVE, permissions utiles et absence de fichiers imprévus. Toute divergence archive/dépôt est un échec d'application.

## Validation
Respecter `default`, `targeted`, `explicit_only`, `forbidden_automatic`, `external_or_live`. Ne jamais inventer une commande. Aucune installation/mise à jour automatique de dépendances. Sur échec obligatoire : arrêter, capturer l'erreur utile, ne pas réparer opportunément.

## Diagnostics
Retour lié au patch : `diagnostics/patch_XXXX/`. Publier uniquement rapport structuré et preuves utiles prévues par projet/manifeste. Jamais secrets, caches, dumps volumineux, données utilisateur ou logs sans rapport. Diagnostics != patch != baseline.

## Git/nettoyage
Sans instruction explicite : aucun commit/push/branche, reset/clean/restore/stash, suppression de non-suivis, nettoyage ou restauration de changements préexistants.

## Rapport
Rapporter fichiers touchés, préexistants pertinents, contrôle post-copie, validations exécutées/non exécutées, diagnostics, état Git et blocages. Ne jamais déclarer une validation non exécutée.
