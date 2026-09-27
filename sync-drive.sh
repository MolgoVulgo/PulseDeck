#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="${ROOT_DIR}/sync-drive.conf"
FILTER_FILE="${ROOT_DIR}/sync-drive.filter"

[[ -f "${CONF_FILE}" ]] || { echo "Erreur: ${CONF_FILE} absent." >&2; exit 1; }
[[ -f "${FILTER_FILE}" ]] || { echo "Erreur: ${FILTER_FILE} absent." >&2; exit 1; }
command -v rclone >/dev/null || { echo "Erreur: rclone absent." >&2; exit 1; }
command -v python3 >/dev/null || { echo "Erreur: python3 absent." >&2; exit 1; }

# shellcheck source=/dev/null
source "${CONF_FILE}"
: "${PROJECT_NAME:?PROJECT_NAME manquant}"
: "${REMOTE:?REMOTE manquant}"
INDEX_FILE="${INDEX_FILE:-REPO_INDEX.json}"
INDEX_PATH="${ROOT_DIR}/${INDEX_FILE}"
TMP_JSON="$(mktemp)"
trap 'rm -f "${TMP_JSON}"' EXIT

echo "Génération de ${INDEX_FILE}..."
rclone lsjson "${ROOT_DIR}" --recursive --files-only --filter-from "${FILTER_FILE}" > "${TMP_JSON}"
python3 - "${INDEX_PATH}" "${PROJECT_NAME}" "${TMP_JSON}" <<'PY'
import json, sys
from datetime import datetime, timezone
from pathlib import Path
index_path=Path(sys.argv[1]); project_name=sys.argv[2]; source=Path(sys.argv[3])
entries=json.loads(source.read_text(encoding="utf-8"))
files=sorted(({"path":e["Path"],"size":e["Size"]} for e in entries), key=lambda x:x["path"])
index={"project":project_name,"generated_at":datetime.now(timezone.utc).isoformat(),"file_count":len(files),"files":files}
index_path.write_text(json.dumps(index,indent=2,ensure_ascii=False)+"\n",encoding="utf-8")
print(f"{len(files)} fichiers indexés")
PY

echo "Synchronisation locale -> ${REMOTE}..."
rclone sync "${ROOT_DIR}" "${REMOTE}" --filter-from "${FILTER_FILE}"
echo "Publication de l'index..."
rclone copyto "${INDEX_PATH}" "${REMOTE}/${INDEX_FILE}"
echo "Synchronisation terminée."
