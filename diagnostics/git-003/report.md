# git-003 application report

## Patch
- Archive: `/tmp/pulsedeck-git-003/git-003.zip`
- Manifest: `PATCH_MANIFEST.md`
- DELETE_FILES.txt: empty
- MOVE_FILES.txt: empty
- Applied branch: `dev`

## Applied files
- `scripts/pulsedeck.sh`
- `scripts/deploy_hub.sh`
- `hub/pyproject.toml`
- `hub/src/pulsedeck_hub/__init__.py`
- `hub/src/pulsedeck_hub/update.py`
- `hub/src/pulsedeck_hub/admin/ui.py`
- `hub/tests/test_update.py`

## Validation
- `bash -n scripts/pulsedeck.sh`: passed
- `bash -n scripts/deploy_hub.sh`: passed
- `python -m py_compile hub/src/pulsedeck_hub/update.py hub/src/pulsedeck_hub/admin/ui.py hub/src/pulsedeck_hub/__init__.py`: passed
- `PYTHONPATH=hub/src python -m pytest -q hub/tests/test_update.py`: passed, 9 tests
- `git diff --check`: passed
- development version declarations: `0.6.0.dev0`
- embedded payload extraction: passed
- embedded payload versions: `0.6.0.dev0`
- embedded payload `pyproject.toml`, `update.py`, `admin/ui.py`: identical to supplied files
- embedded payload `pulsedeck.sh`: identical to supplied launcher at payload root
- embedded payload Python cache check: no `.pytest_cache`, `__pycache__`, `.pyc` or `.pyo`

## Notes
- Raspberry Pi migration command was not executed locally.
- No GitHub Release or tag was created.
