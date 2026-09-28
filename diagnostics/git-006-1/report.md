# git-006-1 application report

## Patch
- Archive: `/tmp/pulsedeck-git-006-1/git-006-1.zip`
- Manifest: `PATCH_MANIFEST.md`
- DELETE_FILES.txt: empty
- MOVE_FILES.txt: empty
- Applied branch: `dev`

## Applied files
- `scripts/deploy_hub.sh`

## Validation
- `git diff --check`: passed
- Diff scope before adding this report: only `scripts/deploy_hub.sh`
- `bash -n scripts/deploy_hub.sh`: passed
- Deployer prefix through `__PULSEDECK_PAYLOAD__`: byte-for-byte unchanged from `HEAD`
- Embedded payload extraction: passed
- Embedded `hub/src/pulsedeck_hub/admin/ui.py`: identical to repository source
- Embedded Admin UI contains `id="updateModal"` and `installUpdateButton` binding to `openUpdateModalConfirm`

## Notes
- No backend updater, systemd unit, Python source, version, privilege model, rollback or cache policy was changed.
- No GitHub Release was created.
