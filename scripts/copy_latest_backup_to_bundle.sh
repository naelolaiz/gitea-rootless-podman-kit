#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
BUNDLE_DIR="$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd -P)"
CONFIG_FILE="${CONFIG_FILE:-${BUNDLE_DIR}/config.env}"

if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck disable=SC1090
  . "${CONFIG_FILE}"
fi

: "${GITEA_BASE_DIR:=/srv/gitea}"
: "${BACKUP_ROOT:=${GITEA_BASE_DIR}/backups}"
: "${STAGED_BACKUP_OWNER:=}"
: "${STAGED_BACKUP_GROUP:=}"
: "${STAGED_BACKUP_MODE:=0600}"

latest="$(
  find "${BACKUP_ROOT}" -maxdepth 1 -type f -name 'gitea-pod-*.tar.zst.age' -printf '%T@ %p\n' \
    | sort -nr \
    | awk 'NR == 1 {print $2}'
)" || true

if [[ -z "${latest}" ]]; then
  printf 'No encrypted backups found in %s\n' "${BACKUP_ROOT}" >&2
  exit 1
fi

install -d -m 0755 "${BUNDLE_DIR}/backups"

dest="${BUNDLE_DIR}/backups/$(basename "${latest}")"
cp "${latest}" "${dest}"
chmod "${STAGED_BACKUP_MODE}" "${dest}"

if [[ -f "${latest}.sha256" ]]; then
  sha_dest="${BUNDLE_DIR}/backups/$(basename "${latest}.sha256")"
  cp "${latest}.sha256" "${sha_dest}"
  chmod "${STAGED_BACKUP_MODE}" "${sha_dest}"
fi

if [[ -n "${STAGED_BACKUP_OWNER}" ]]; then
  chown_targets=("${dest}")
  if [[ -n "${sha_dest:-}" ]]; then
    chown_targets+=("${sha_dest}")
  fi
  if [[ -n "${STAGED_BACKUP_GROUP}" ]]; then
    chown "${STAGED_BACKUP_OWNER}:${STAGED_BACKUP_GROUP}" "${chown_targets[@]}" 2>/dev/null || true
  else
    chown "${STAGED_BACKUP_OWNER}" "${chown_targets[@]}" 2>/dev/null || true
  fi
fi

printf 'Copied %s\n' "${latest}"
