#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
BUNDLE_DIR="$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd -P)"
CONFIG_FILE="${CONFIG_FILE:-${BUNDLE_DIR}/config.env}"

if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck disable=SC1090
  . "${CONFIG_FILE}"
fi

# Default mode: create an encrypted local backup and stage a copy under backups/.
: "${SCHEDULED_BACKUP_STAGE_TO_BUNDLE:=1}"
: "${SCHEDULED_BACKUP_STAGED_MODE:=0600}"

# Optional Git-backed storage mode. Disabled by default.
: "${SCHEDULED_BACKUP_GIT_ENABLE:=0}"
: "${SCHEDULED_BACKUP_GIT_USER:=}"
: "${SCHEDULED_BACKUP_GIT_GROUP:=}"
: "${SCHEDULED_BACKUP_GIT_PUSH:=0}"
: "${SCHEDULED_BACKUP_GIT_REMOTE:=origin}"
: "${SCHEDULED_BACKUP_GIT_BRANCH:=main}"
: "${SCHEDULED_BACKUP_GIT_COMMIT_PREFIX:=Automated encrypted Gitea backup}"
: "${SCHEDULED_BACKUP_GIT_REQUIRE_CLEAN:=1}"
: "${SCHEDULED_BACKUP_GIT_KEEP_REPO_BACKUPS:=0}"

log() { printf '[%s] %s\n' "$(date +'%F %T')" "$*"; }
fail() { printf '[%s] ERROR: %s\n' "$(date +'%F %T')" "$*" >&2; exit 1; }

shell_quote() {
  printf '%q' "$1"
}

[[ "$(id -u)" -eq 0 ]] || fail "Run as root; backup needs access to service data and pod control"

run_as_repo_user() {
  local cmd=""
  local arg
  for arg in "$@"; do
    cmd+=" $(shell_quote "${arg}")"
  done
  cmd="cd $(shell_quote "${BUNDLE_DIR}") &&${cmd}"
  su -s /bin/bash -c "${cmd}" "${SCHEDULED_BACKUP_GIT_USER}"
}

if [[ "${SCHEDULED_BACKUP_GIT_ENABLE}" == "1" ]]; then
  [[ "${SCHEDULED_BACKUP_STAGE_TO_BUNDLE}" == "1" ]] || fail "SCHEDULED_BACKUP_GIT_ENABLE=1 requires SCHEDULED_BACKUP_STAGE_TO_BUNDLE=1"
  command -v git >/dev/null || fail "Missing git"
  [[ -d "${BUNDLE_DIR}/.git" ]] || fail "Not a Git repository: ${BUNDLE_DIR}"

  if [[ -z "${SCHEDULED_BACKUP_GIT_USER}" ]]; then
    SCHEDULED_BACKUP_GIT_USER="$(stat -c '%U' "${BUNDLE_DIR}")"
  fi
  if [[ -z "${SCHEDULED_BACKUP_GIT_GROUP}" ]]; then
    SCHEDULED_BACKUP_GIT_GROUP="$(stat -c '%G' "${BUNDLE_DIR}")"
  fi

  id "${SCHEDULED_BACKUP_GIT_USER}" >/dev/null || fail "Missing SCHEDULED_BACKUP_GIT_USER: ${SCHEDULED_BACKUP_GIT_USER}"
  getent group "${SCHEDULED_BACKUP_GIT_GROUP}" >/dev/null || fail "Missing SCHEDULED_BACKUP_GIT_GROUP: ${SCHEDULED_BACKUP_GIT_GROUP}"
  run_as_repo_user git rev-parse --is-inside-work-tree >/dev/null

  if [[ "${SCHEDULED_BACKUP_GIT_REQUIRE_CLEAN}" == "1" ]]; then
    tracked_status="$(run_as_repo_user git status --porcelain --untracked-files=no)"
    if [[ -n "${tracked_status}" ]]; then
      printf '%s\n' "${tracked_status}" >&2
      fail "Repository has tracked changes. Commit or stash them, or set SCHEDULED_BACKUP_GIT_REQUIRE_CLEAN=0."
    fi
  fi

  export STAGED_BACKUP_OWNER="${SCHEDULED_BACKUP_GIT_USER}"
  export STAGED_BACKUP_GROUP="${SCHEDULED_BACKUP_GIT_GROUP}"
fi

export STAGED_BACKUP_MODE="${SCHEDULED_BACKUP_STAGED_MODE}"

if [[ "${SCHEDULED_BACKUP_STAGE_TO_BUNDLE}" == "1" ]]; then
  log "Creating encrypted backup and staging a local copy under backups/"
  "${SCRIPT_DIR}/create_and_stage_backup.sh"
else
  log "Creating encrypted backup in BACKUP_ROOT only"
  "${SCRIPT_DIR}/backup_gitea_pod.sh"
fi

if [[ "${SCHEDULED_BACKUP_GIT_ENABLE}" != "1" ]]; then
  log "Scheduled backup completed"
  exit 0
fi

latest="$(
  find "${BUNDLE_DIR}/backups" -maxdepth 1 -type f -name 'gitea-pod-*.tar.zst.age' -printf '%T@ %p\n' \
    | sort -nr \
    | awk 'NR == 1 {print $2}'
)" || true

[[ -n "${latest}" ]] || fail "No staged encrypted backup found in ${BUNDLE_DIR}/backups"
sha="${latest}.sha256"
[[ -f "${sha}" ]] || fail "Missing checksum for staged backup: ${sha}"

chown "${SCHEDULED_BACKUP_GIT_USER}:${SCHEDULED_BACKUP_GIT_GROUP}" "${latest}" "${sha}"
chmod "${SCHEDULED_BACKUP_STAGED_MODE}" "${latest}" "${sha}"

if [[ "${SCHEDULED_BACKUP_GIT_KEEP_REPO_BACKUPS}" =~ ^[0-9]+$ ]] && [[ "${SCHEDULED_BACKUP_GIT_KEEP_REPO_BACKUPS}" -gt 0 ]]; then
  log "Keeping newest ${SCHEDULED_BACKUP_GIT_KEEP_REPO_BACKUPS} encrypted backups in repo working tree"
  mapfile -t old_backups < <(
    find "${BUNDLE_DIR}/backups" -maxdepth 1 -type f -name 'gitea-pod-*.tar.zst.age' -printf '%T@ %p\n' \
      | sort -nr \
      | awk -v keep="${SCHEDULED_BACKUP_GIT_KEEP_REPO_BACKUPS}" 'NR > keep {print $2}'
  )
  for old in "${old_backups[@]}"; do
    rm -f "${old}" "${old}.sha256"
  done
fi

rel_latest="backups/$(basename "${latest}")"
rel_sha="backups/$(basename "${sha}")"

log "Committing encrypted backup to Git-backed storage"
run_as_repo_user git add -u backups
run_as_repo_user git add -f "${rel_latest}" "${rel_sha}"

if run_as_repo_user git diff --cached --quiet; then
  log "No backup changes to commit"
else
  run_as_repo_user git commit -m "${SCHEDULED_BACKUP_GIT_COMMIT_PREFIX} $(date +%F_%H%M%S)"
fi

if [[ "${SCHEDULED_BACKUP_GIT_PUSH}" == "1" ]]; then
  log "Pushing to ${SCHEDULED_BACKUP_GIT_REMOTE} ${SCHEDULED_BACKUP_GIT_BRANCH}"
  run_as_repo_user git push "${SCHEDULED_BACKUP_GIT_REMOTE}" "${SCHEDULED_BACKUP_GIT_BRANCH}"
else
  log "Skipping git push because SCHEDULED_BACKUP_GIT_PUSH=${SCHEDULED_BACKUP_GIT_PUSH}"
fi

log "Scheduled backup completed"
