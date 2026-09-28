# git-007-1 application report

## Patch
- Archive: `/tmp/pulsedeck-git-007-1/git-007-1.zip`
- Manifest: `PATCH_MANIFEST.md`
- DELETE_FILES.txt: empty
- MOVE_FILES.txt: empty
- Applied branch: `dev`

## Applied files
- `hub/src/pulsedeck_hub/admin/ui.py`
- `hub/tests/test_admin.py`
- `scripts/deploy_hub.sh`

## Validation
- `git diff --check`: passed
- `bash -n scripts/deploy_hub.sh`: passed
- `python -m py_compile hub/src/pulsedeck_hub/admin/ui.py hub/tests/test_admin.py`: passed
- `PYTHONPATH=hub/src python -m pytest -q hub/tests/test_admin.py`: passed, 9 tests
- Embedded deploy payload extraction: passed
- Embedded Admin UI is identical to repository `hub/src/pulsedeck_hub/admin/ui.py`
- Embedded Admin UI contains `restartSeen`, `Vérification finale`, and restart/reconnect modal states

## Notes
- Backend API, updater worker, systemd units, configuration and privilege model were not changed.
- Live modal flow was not executed locally.
