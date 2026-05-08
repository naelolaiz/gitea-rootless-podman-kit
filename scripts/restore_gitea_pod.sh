#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
BUNDLE_DIR="$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd -P)"
CONFIG_FILE="${CONFIG_FILE:-${BUNDLE_DIR}/config.env}"

if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck disable=SC1090
  . "${CONFIG_FILE}"
fi

: "${POD_NAME:=gitea}"
: "${CTR_NAME:=gitea-server}"
: "${IMAGE:=docker.gitea.com/gitea:1.26.1-rootless}"
: "${PODMAN_USER:=git}"
: "${PODMAN_GROUP:=git}"
: "${PODMAN_XDG_RUNTIME_DIR:=/run/podman-gitea}"
: "${GITEA_BASE_DIR:=/srv/gitea}"
: "${HOST_DATA_DIR:=${GITEA_BASE_DIR}/var/lib/gitea}"
: "${HOST_RUNNER_DIR:=${GITEA_BASE_DIR}/var/lib/act_runner}"
: "${CONFIG_VOLUME:=gitea-config}"
: "${HTTP_BIND:=127.0.0.1}"
: "${HTTP_HOST_PORT:=3000}"
: "${SSH_BIND:=127.0.0.1}"
: "${SSH_HOST_PORT:=2222}"
: "${CONTAINER_GIT_UID:=1000}"
: "${CONTAINER_GIT_GID:=1000}"
: "${BACKUP_ARCHIVE:=}"
: "${AGE_IDENTITY:=}"
: "${FORCE_RESTORE:=0}"
: "${SKIP_PULL:=0}"

if [[ -n "${BACKUP_ARCHIVE}" && "${BACKUP_ARCHIVE}" != /* ]]; then
  BACKUP_ARCHIVE="${BUNDLE_DIR}/${BACKUP_ARCHIVE#./}"
fi
if [[ -n "${AGE_IDENTITY}" && "${AGE_IDENTITY}" != /* ]]; then
  AGE_IDENTITY="${BUNDLE_DIR}/${AGE_IDENTITY#./}"
fi

PODMAN_USERNS="keep-id:uid=${CONTAINER_GIT_UID},gid=${CONTAINER_GIT_GID}"

log() { printf '[%s] %s\n' "$(date +'%F %T')" "$*"; }
fail() { printf '[%s] ERROR: %s\n' "$(date +'%F %T')" "$*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || fail "Run as root"
[[ -n "${BACKUP_ARCHIVE}" ]] || fail "Set BACKUP_ARCHIVE=/path/to/gitea-pod-....tar.zst.age"
[[ -f "${BACKUP_ARCHIVE}" ]] || fail "Missing backup archive: ${BACKUP_ARCHIVE}"
[[ -n "${AGE_IDENTITY}" ]] || fail "Set AGE_IDENTITY=/path/to/private.agekey"
[[ -f "${AGE_IDENTITY}" ]] || fail "Missing AGE_IDENTITY: ${AGE_IDENTITY}"

command -v age >/dev/null || fail "Missing age"
command -v zstd >/dev/null || fail "Missing zstd"
command -v tar >/dev/null || fail "Missing tar"
command -v podman >/dev/null || fail "Missing podman"
id "${PODMAN_USER}" >/dev/null || fail "Missing system user: ${PODMAN_USER}"
getent group "${PODMAN_GROUP}" >/dev/null || fail "Missing system group: ${PODMAN_GROUP}"

as_podman_user() {
  local cmd="$1"
  su -s /bin/bash -c "XDG_RUNTIME_DIR='${PODMAN_XDG_RUNTIME_DIR}' bash -lc \"${cmd}\"" "${PODMAN_USER}"
}

dir_has_contents() {
  [[ -d "$1" ]] && find "$1" -mindepth 1 -maxdepth 1 -print -quit | grep -q .
}

clear_dir() {
  local dir="$1"
  install -d -m 0750 -o "${PODMAN_USER}" -g "${PODMAN_GROUP}" "${dir}"
  if dir_has_contents "${dir}"; then
    [[ "${FORCE_RESTORE}" == "1" ]] || fail "${dir} is not empty. Re-run with FORCE_RESTORE=1 to overwrite."
    find "${dir}" -mindepth 1 -exec rm -rf {} +
  fi
}

umask 077
STAGE="$(mktemp -d /tmp/gitea-restore.XXXXXX)"
cleanup() {
  rm -rf "${STAGE}"
}
trap cleanup EXIT

log "Decrypting backup into temporary staging"
age -d -i "${AGE_IDENTITY}" "${BACKUP_ARCHIVE}" | zstd -d | tar -C "${STAGE}" -xpf -

RESTORE_GITEA_DIR=""
for db_path in "${STAGE}"/*/data/gitea.db; do
  if [[ -f "${db_path}" ]]; then
    RESTORE_GITEA_DIR="$(dirname "$(dirname "${db_path}")")"
    break
  fi
done

[[ -n "${RESTORE_GITEA_DIR}" ]] || fail "Backup does not contain a top-level */data/gitea.db"
[[ -f "${STAGE}/config/app.ini" ]] || fail "Backup does not contain config/app.ini"

install -d -m 0700 -o "${PODMAN_USER}" -g "${PODMAN_GROUP}" "${PODMAN_XDG_RUNTIME_DIR}"

if as_podman_user "podman pod exists '${POD_NAME}'"; then
  [[ "${FORCE_RESTORE}" == "1" ]] || fail "Pod ${POD_NAME} already exists. Re-run with FORCE_RESTORE=1 to replace it."
  log "Removing existing pod/container"
  as_podman_user "podman rm -f '${CTR_NAME}' >/dev/null 2>&1 || true"
  as_podman_user "podman pod rm -f '${POD_NAME}' >/dev/null 2>&1 || true"
fi

log "Restoring Gitea data directory"
clear_dir "${HOST_DATA_DIR}"
tar -C "${RESTORE_GITEA_DIR}" -cf - . | tar -C "${HOST_DATA_DIR}" -xpf -
chown -R "${PODMAN_USER}:${PODMAN_GROUP}" "${HOST_DATA_DIR}"

RESTORE_RUNNER_DIR=""
if [[ -d "${STAGE}/act_runner" ]]; then
  RESTORE_RUNNER_DIR="${STAGE}/act_runner"
elif [[ -d "${STAGE}/$(basename "${HOST_RUNNER_DIR}")" ]]; then
  RESTORE_RUNNER_DIR="${STAGE}/$(basename "${HOST_RUNNER_DIR}")"
fi

if [[ -n "${RESTORE_RUNNER_DIR}" ]]; then
  log "Restoring act_runner directory"
  clear_dir "${HOST_RUNNER_DIR}"
  tar -C "${RESTORE_RUNNER_DIR}" -cf - . | tar -C "${HOST_RUNNER_DIR}" -xpf -
  chown -R "${PODMAN_USER}:${PODMAN_GROUP}" "${HOST_RUNNER_DIR}"
fi

if [[ "${SKIP_PULL}" != "1" ]]; then
  log "Pulling image: ${IMAGE}"
  as_podman_user "podman pull '${IMAGE}'"
fi

log "Restoring config volume: ${CONFIG_VOLUME}"
as_podman_user "podman volume exists '${CONFIG_VOLUME}' || podman volume create '${CONFIG_VOLUME}' >/dev/null"
tar -C "${STAGE}/config" -cf - . \
  | as_podman_user "podman run --rm -i --userns '${PODMAN_USERNS}' -v '${CONFIG_VOLUME}:/etc/gitea:rw' --entrypoint /bin/sh '${IMAGE}' -c 'find /etc/gitea -mindepth 1 -exec rm -rf {} +; tar -C /etc/gitea -xf -; chmod 0644 /etc/gitea/app.ini; test -r /etc/gitea/app.ini'"

log "Creating pod"
as_podman_user "podman pod create --name '${POD_NAME}' --replace --userns '${PODMAN_USERNS}' -p '${HTTP_BIND}:${HTTP_HOST_PORT}:3000' -p '${SSH_BIND}:${SSH_HOST_PORT}:2222'"

log "Creating and starting Gitea container"
as_podman_user "podman run -d --name '${CTR_NAME}' --replace --pod '${POD_NAME}' --restart unless-stopped -v '${HOST_DATA_DIR}:/var/lib/gitea:rw' -v '${CONFIG_VOLUME}:/etc/gitea:rw' --entrypoint /bin/sh '${IMAGE}' -c 'exec gitea --config /etc/gitea/app.ini --work-path /var/lib/gitea web'"

sleep 4
as_podman_user "podman pod ps --filter name='${POD_NAME}'"
as_podman_user "podman logs --tail 80 '${CTR_NAME}'"

curl -fsS "http://${HTTP_BIND}:${HTTP_HOST_PORT}/" >/dev/null || fail "HTTP probe failed"

log "Regenerating hooks/keys"
as_podman_user "podman exec '${CTR_NAME}' gitea --config /etc/gitea/app.ini --work-path /var/lib/gitea admin regenerate hooks"
as_podman_user "podman exec '${CTR_NAME}' gitea --config /etc/gitea/app.ini --work-path /var/lib/gitea admin regenerate keys"

log "Restore completed"
