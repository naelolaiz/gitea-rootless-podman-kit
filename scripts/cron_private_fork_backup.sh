#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
BUNDLE_DIR="$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd -P)"
CONFIG_FILE="${CONFIG_FILE:-${BUNDLE_DIR}/config.env}"

if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck disable=SC1090
  . "${CONFIG_FILE}"
fi

: "${PRIVATE_BACKUP_GIT_USER:=}"
: "${PRIVATE_BACKUP_GIT_GROUP:=}"
: "${PRIVATE_BACKUP_PUSH:=0}"
: "${PRIVATE_BACKUP_GIT_REMOTE:=origin}"
: "${PRIVATE_BACKUP_GIT_BRANCH:=main}"
: "${PRIVATE_BACKUP_COMMIT_PREFIX:=Automated encrypted Gitea backup}"
: "${PRIVATE_BACKUP_REQUIRE_CLEAN:=1}"
: "${PRIVATE_BACKUP_KEEP_REPO_BACKUPS:=0}"

log() { printf '[%s] %s\n' "$(date +'%F %T')" "$*"; }
fail() { printf '[%s] ERROR: %s\n' "$(date +'%F %T')" "$*" >&2; exit 1; }

shell_quote() {
  printf '%q' "$1"
}

[[ "$(id -u)" -eq 0 ]] || fail "Run as root; backup needs access to service data and pod control"
command -v git >/dev/null || fail "Missing git"
[[ -d "${BUNDLE_DIR}/.git" ]] || fail "Not a Git repository: ${BUNDLE_DIR}"

if [[ -z "${PRIVATE_BACKUP_GIT_USER}" ]]; then
  PRIVATE_BACKUP_GIT_USER="$(stat -c '%U' "${BUNDLE_DIR}")"
fi
if [[ -z "${PRIVATE_BACKUP_GIT_GROUP}" ]]; then
  PRIVATE_BACKUP_GIT_GROUP="$(stat -c '%G' "${BUNDLE_DIR}")"
fi

id "${PRIVATE_BACKUP_GIT_USER}" >/dev/null || fail "Missing PRIVATE_BACKUP_GIT_USER: ${PRIVATE_BACKUP_GIT_USER}"
getent group "${PRIVATE_BACKUP_GIT_GROUP}" >/dev/null || fail "Missing PRIVATE_BACKUP_GIT_GROUP: ${PRIVATE_BACKUP_GIT_GROUP}"

run_as_repo_user() {
  local cmd=""
  local arg
  for arg in "$@"; do
    cmd+=" $(shell_quote "${arg}")"
  done
  cmd="cd $(shell_quote "${BUNDLE_DIR}") &&${cmd}"
  su -s /bin/bash -c "${cmd}" "${PRIVATE_BACKUP_GIT_USER}"
}

run_as_repo_user git rev-parse --is-inside-work-tree >/dev/null

if [[ "${PRIVATE_BACKUP_REQUIRE_CLEAN}" == "1" ]]; then
  tracked_status="$(run_as_repo_user git status --porcelain --untracked-files=no)"
  if [[ -n "${tracked_status}" ]]; then
    printf '%s\n' "${tracked_status}" >&2
    fail "Repository has tracked changes. Commit or stash them, or set PRIVATE_BACKUP_REQUIRE_CLEAN=0."
  fi
fi

log "Creating encrypted backup and staging it in backups/"
export STAGED_BACKUP_OWNER="${PRIVATE_BACKUP_GIT_USER}"
export STAGED_BACKUP_GROUP="${PRIVATE_BACKUP_GIT_GROUP}"
export STAGED_BACKUP_MODE="0600"
"${SCRIPT_DIR}/create_and_stage_backup.sh"

latest="$(
  find "${BUNDLE_DIR}/backups" -maxdepth 1 -type f -name 'gitea-pod-*.tar.zst.age' -printf '%T@ %p\n' \
    | sort -nr \
    | awk 'NR == 1 {print $2}'
)" || true

[[ -n "${latest}" ]] || fail "No staged encrypted backup found in ${BUNDLE_DIR}/backups"
sha="${latest}.sha256"
[[ -f "${sha}" ]] || fail "Missing checksum for staged backup: ${sha}"

chown "${PRIVATE_BACKUP_GIT_USER}:${PRIVATE_BACKUP_GIT_GROUP}" "${latest}" "${sha}"
chmod 0600 "${latest}" "${sha}"

if [[ "${PRIVATE_BACKUP_KEEP_REPO_BACKUPS}" =~ ^[0-9]+$ ]] && [[ "${PRIVATE_BACKUP_KEEP_REPO_BACKUPS}" -gt 0 ]]; then
  log "Keeping newest ${PRIVATE_BACKUP_KEEP_REPO_BACKUPS} encrypted backups in repo working tree"
  mapfile -t old_backups < <(
    find "${BUNDLE_DIR}/backups" -maxdepth 1 -type f -name 'gitea-pod-*.tar.zst.age' -printf '%T@ %p\n' \
      | sort -nr \
      | awk -v keep="${PRIVATE_BACKUP_KEEP_REPO_BACKUPS}" 'NR > keep {print $2}'
  )
  for old in "${old_backups[@]}"; do
    rm -f "${old}" "${old}.sha256"
  done
fi

rel_latest="backups/$(basename "${latest}")"
rel_sha="backups/$(basename "${sha}")"

log "Committing encrypted backup to private fork working tree"
run_as_repo_user git add -u backups
run_as_repo_user git add -f "${rel_latest}" "${rel_sha}"

if run_as_repo_user git diff --cached --quiet; then
  log "No backup changes to commit"
else
  run_as_repo_user git commit -m "${PRIVATE_BACKUP_COMMIT_PREFIX} $(date +%F_%H%M%S)"
fi

if [[ "${PRIVATE_BACKUP_PUSH}" == "1" ]]; then
  log "Pushing to ${PRIVATE_BACKUP_GIT_REMOTE} ${PRIVATE_BACKUP_GIT_BRANCH}"
  run_as_repo_user git push "${PRIVATE_BACKUP_GIT_REMOTE}" "${PRIVATE_BACKUP_GIT_BRANCH}"
else
  log "Skipping git push because PRIVATE_BACKUP_PUSH=${PRIVATE_BACKUP_PUSH}"
fi

log "Private-fork backup workflow completed"
