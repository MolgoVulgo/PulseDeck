# git-006 application report

## Patch
- Archive: `/tmp/pulsedeck-git-006/git-006.zip`
- Manifest: `PATCH_MANIFEST.md`
- DELETE_FILES.txt: no files to delete
- MOVE_FILES.txt: no files to move
- Applied branch: `dev`

## Applied files
- `scripts/deploy_hub.sh`
- `docs/pi/INSTALL.md`
- `docs/pi/fr/INSTALL.md`

## Validation
- `bash -n scripts/deploy_hub.sh`: passed
- `git diff --check`: passed
- embedded `scripts/deploy_hub.sh` payload compared against `HEAD`: identical
- Diff scope before adding this report: limited to the three supplied files

## Notes
- Worker root, systemd units, Web Admin modal, API update routes and stable/dev channel contract were not changed.
- Live Raspberry Pi update validation was not executed locally.
