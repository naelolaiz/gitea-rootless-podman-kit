#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
BUNDLE_DIR="$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd -P)"
CONFIG_FILE="${CONFIG_FILE:-${BUNDLE_DIR}/config.env}"

if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck disable=SC1090
  . "${CONFIG_FILE}"
fi

: "${BACKUP_ROOT:?Set BACKUP_ROOT in config.env or environment}"
: "${HOST_DATA_DIR:?Set HOST_DATA_DIR in config.env or environment}"
: "${AGE_RECIPIENTS_FILE:=${BUNDLE_DIR}/keys/gitea-backup.recipient}"

export BACKUP_ROOT
export HOST_DATA_DIR
export AGE_RECIPIENTS_FILE

"${SCRIPT_DIR}/backup_gitea_pod.sh"
"${SCRIPT_DIR}/copy_latest_backup_to_bundle.sh"

printf '\nStaged backup files:\n'
ls -lh "${BUNDLE_DIR}/backups"
