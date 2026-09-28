# git-001 application report

## Patch
- Archive: `/tmp/pulsedeck-git-001/git-001.zip`
- Manifest: `PATCH_MANIFEST.md`
- DELETE_FILES.txt: empty
- MOVE_FILES.txt: empty

## Applied files
- `.github/workflows/release.yml`
- `scripts/check_release_version.py`
- `scripts/build_release.sh`

## Permissions
- `.github/workflows/release.yml`: `644`
- `scripts/check_release_version.py`: `755`
- `scripts/build_release.sh`: `755`

## Validation
- `bash -n scripts/build_release.sh`: passed
- `python -m py_compile scripts/check_release_version.py`: passed
- `git diff --check`: passed

## Notes
- `scripts/__pycache__/` was created by `python -m py_compile` and removed after validation.
- No tag, commit, push or release was created.
