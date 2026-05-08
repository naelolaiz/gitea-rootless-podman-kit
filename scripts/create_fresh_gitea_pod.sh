#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
BUNDLE_DIR="$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd -P)"
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
: "${CONFIG_VOLUME:=gitea-config}"
: "${HTTP_BIND:=127.0.0.1}"
: "${HTTP_HOST_PORT:=3000}"
: "${SSH_BIND:=127.0.0.1}"
: "${SSH_HOST_PORT:=2222}"
: "${CONTAINER_GIT_UID:=1000}"
: "${CONTAINER_GIT_GID:=1000}"
: "${FRESH_APP_NAME:=Gitea}"
: "${FRESH_DOMAIN:=localhost}"
: "${FRESH_SSH_DOMAIN:=${FRESH_DOMAIN}}"
: "${FRESH_ROOT_URL:=http://${HTTP_BIND}:${HTTP_HOST_PORT}/}"
: "${FORCE_CREATE:=0}"
: "${SKIP_PULL:=0}"

PODMAN_USERNS="keep-id:uid=${CONTAINER_GIT_UID},gid=${CONTAINER_GIT_GID}"

log() { printf '[%s] %s\n' "$(date +'%F %T')" "$*"; }
fail() { printf '[%s] ERROR: %s\n' "$(date +'%F %T')" "$*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || fail "Run as root"
command -v podman >/dev/null || fail "Missing podman"
command -v tar >/dev/null || fail "Missing tar"
command -v curl >/dev/null || fail "Missing curl"
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
    [[ "${FORCE_CREATE}" == "1" ]] || fail "${dir} is not empty. Re-run with FORCE_CREATE=1 to replace it."
    find "${dir}" -mindepth 1 -exec rm -rf {} +
  fi
}

umask 077
STAGE="$(mktemp -d /tmp/gitea-fresh.XXXXXX)"
cleanup() {
  rm -rf "${STAGE}"
}
trap cleanup EXIT

install -d -m 0700 -o "${PODMAN_USER}" -g "${PODMAN_GROUP}" "${PODMAN_XDG_RUNTIME_DIR}"

if as_podman_user "podman pod exists '${POD_NAME}'"; then
  [[ "${FORCE_CREATE}" == "1" ]] || fail "Pod ${POD_NAME} already exists. Re-run with FORCE_CREATE=1 to replace it."
  log "Removing existing pod/container"
  as_podman_user "podman rm -f '${CTR_NAME}' >/dev/null 2>&1 || true"
  as_podman_user "podman pod rm -f '${POD_NAME}' >/dev/null 2>&1 || true"
fi

log "Preparing empty Gitea data directory"
clear_dir "${HOST_DATA_DIR}"
install -d -m 0750 -o "${PODMAN_USER}" -g "${PODMAN_GROUP}" \
  "${HOST_DATA_DIR}/custom" \
  "${HOST_DATA_DIR}/data" \
  "${HOST_DATA_DIR}/log"

if [[ "${SKIP_PULL}" != "1" ]]; then
  log "Pulling image: ${IMAGE}"
  as_podman_user "podman pull '${IMAGE}'"
fi

log "Creating starter app.ini for web installer"
mkdir -p "${STAGE}/config"
cat > "${STAGE}/config/app.ini" <<EOF
APP_NAME = ${FRESH_APP_NAME}
RUN_MODE = prod
WORK_PATH = /var/lib/gitea

[server]
APP_DATA_PATH = /var/lib/gitea/data
DOMAIN = ${FRESH_DOMAIN}
HTTP_ADDR = 0.0.0.0
HTTP_PORT = 3000
ROOT_URL = ${FRESH_ROOT_URL}
DISABLE_SSH = false
SSH_DOMAIN = ${FRESH_SSH_DOMAIN}
SSH_PORT = ${SSH_HOST_PORT}
START_SSH_SERVER = true
SSH_LISTEN_PORT = 2222
LFS_START_SERVER = true

[database]
DB_TYPE = sqlite3
PATH = /var/lib/gitea/data/gitea.db

[repository]
ROOT = /var/lib/gitea/data/gitea-repositories

[log]
MODE = console
LEVEL = info
ROOT_PATH = /var/lib/gitea/log

[security]
INSTALL_LOCK = false
EOF

log "Creating config volume: ${CONFIG_VOLUME}"
if as_podman_user "podman volume exists '${CONFIG_VOLUME}'"; then
  [[ "${FORCE_CREATE}" == "1" ]] || fail "Config volume ${CONFIG_VOLUME} already exists. Re-run with FORCE_CREATE=1 to replace it."
else
  as_podman_user "podman volume create '${CONFIG_VOLUME}' >/dev/null"
fi

tar -C "${STAGE}/config" -cf - . \
  | as_podman_user "podman run --rm -i --userns '${PODMAN_USERNS}' -v '${CONFIG_VOLUME}:/etc/gitea:rw' --entrypoint /bin/sh '${IMAGE}' -c 'find /etc/gitea -mindepth 1 -exec rm -rf {} +; tar -C /etc/gitea -xf -; chmod 0644 /etc/gitea/app.ini; test -r /etc/gitea/app.ini; test -w /etc/gitea/app.ini'"

log "Creating pod"
as_podman_user "podman pod create --name '${POD_NAME}' --replace --userns '${PODMAN_USERNS}' -p '${HTTP_BIND}:${HTTP_HOST_PORT}:3000' -p '${SSH_BIND}:${SSH_HOST_PORT}:2222'"

log "Creating and starting Gitea container"
as_podman_user "podman run -d --name '${CTR_NAME}' --replace --pod '${POD_NAME}' --restart unless-stopped -v '${HOST_DATA_DIR}:/var/lib/gitea:rw' -v '${CONFIG_VOLUME}:/etc/gitea:rw' --entrypoint /bin/sh '${IMAGE}' -c 'exec gitea --config /etc/gitea/app.ini --work-path /var/lib/gitea web'"

sleep 4
as_podman_user "podman pod ps --filter name='${POD_NAME}'"
as_podman_user "podman logs --tail 80 '${CTR_NAME}'"

curl -fsS "http://${HTTP_BIND}:${HTTP_HOST_PORT}/" >/dev/null || fail "HTTP probe failed"

log "Fresh Gitea pod created"
printf 'Open %s and complete the Gitea web installer.\n' "${FRESH_ROOT_URL}"
printf 'After installation, run ./scripts/create_and_stage_backup.sh to create the first encrypted backup.\n'
