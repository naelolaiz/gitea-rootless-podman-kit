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
: "${PODMAN_USER:=git}"
: "${PODMAN_XDG_RUNTIME_DIR:=/run/podman-gitea}"
: "${IMAGE:=docker.gitea.com/gitea:1.26.1-rootless}"
: "${GITEA_BASE_DIR:=/srv/gitea}"
: "${HOST_DATA_DIR:=${GITEA_BASE_DIR}/var/lib/gitea}"
: "${HOST_RUNNER_DIR:=${GITEA_BASE_DIR}/var/lib/act_runner}"
: "${CONFIG_VOLUME:=gitea-config}"
: "${BACKUP_ROOT:=${GITEA_BASE_DIR}/backups}"
: "${KEEP_DAYS:=30}"
: "${ZSTD_LEVEL:=12}"
: "${ZSTD_THREADS:=0}"
: "${ZSTD_LONG:=--long=27}"
: "${AGE_RECIPIENT:=}"
: "${AGE_RECIPIENTS_FILE:=}"
: "${AGE_PASSPHRASE:=0}"

if [[ -n "${AGE_RECIPIENTS_FILE}" && "${AGE_RECIPIENTS_FILE}" != /* ]]; then
  AGE_RECIPIENTS_FILE="${BUNDLE_DIR}/${AGE_RECIPIENTS_FILE#./}"
fi

log() { printf '[%s] %s\n' "$(date +'%F %T')" "$*"; }
fail() { printf '[%s] ERROR: %s\n' "$(date +'%F %T')" "$*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || fail "Run as root"
[[ -d "${HOST_DATA_DIR}" ]] || fail "Missing data dir: ${HOST_DATA_DIR}"

command -v age >/dev/null || fail "Missing age"
command -v zstd >/dev/null || fail "Missing zstd"
command -v tar >/dev/null || fail "Missing tar"

if [[ -n "${AGE_RECIPIENT}" && -n "${AGE_RECIPIENTS_FILE}" ]]; then
  fail "Use AGE_RECIPIENT or AGE_RECIPIENTS_FILE, not both"
fi
if [[ -z "${AGE_RECIPIENT}" && -z "${AGE_RECIPIENTS_FILE}" && "${AGE_PASSPHRASE}" != "1" ]]; then
  fail "Set AGE_RECIPIENT, AGE_RECIPIENTS_FILE, or AGE_PASSPHRASE=1"
fi
if [[ -n "${AGE_RECIPIENTS_FILE}" && ! -f "${AGE_RECIPIENTS_FILE}" ]]; then
  fail "Missing AGE_RECIPIENTS_FILE: ${AGE_RECIPIENTS_FILE}"
fi

as_podman_user() {
  local cmd="$1"
  su -s /bin/bash -c "XDG_RUNTIME_DIR='${PODMAN_XDG_RUNTIME_DIR}' bash -lc \"${cmd}\"" "${PODMAN_USER}"
}

as_podman_user "podman volume exists '${CONFIG_VOLUME}'" || fail "Missing config volume: ${CONFIG_VOLUME}"

umask 077
mkdir -p "${BACKUP_ROOT}"
TS="$(date +%F_%H%M%S)"
OUT="${BACKUP_ROOT}/gitea-pod-${TS}.tar.zst.age"
SHA="${OUT}.sha256"
STAGE="$(mktemp -d /tmp/gitea-backup.XXXXXX)"

cleanup() {
  rm -rf "${STAGE}"
}

if (( ZSTD_LEVEL >= 20 )); then
  ZSTD_EXTRA=(--ultra)
else
  ZSTD_EXTRA=()
fi

WAS_RUNNING="no"
POD_STATE="$(as_podman_user "podman pod inspect '${POD_NAME}' --format '{{.State}}'" 2>/dev/null || true)"
if [[ "${POD_STATE}" == "Running" ]]; then
  WAS_RUNNING="yes"
fi

restart_if_needed() {
  if [[ "${WAS_RUNNING}" == "yes" ]]; then
    log "Restarting pod ${POD_NAME}"
    as_podman_user "podman pod start '${POD_NAME}' >/dev/null"
  fi
}
trap 'restart_if_needed; cleanup' EXIT

if [[ "${WAS_RUNNING}" == "yes" ]]; then
  log "Stopping pod ${POD_NAME} for consistent backup"
  as_podman_user "podman pod stop -t 30 '${POD_NAME}' >/dev/null"
else
  log "Pod ${POD_NAME} already stopped"
fi

log "Exporting config volume"
mkdir -p "${STAGE}/config"
as_podman_user "podman run --rm -v '${CONFIG_VOLUME}:/config:ro' --entrypoint /bin/sh '${IMAGE}' -c 'tar -C /config -cf - .'" \
  | tar -C "${STAGE}/config" -xf -

DATA_BASE="$(basename "${HOST_DATA_DIR}")"
DATA_PARENT="$(dirname "${HOST_DATA_DIR}")"
RUNNER_TAR_ARGS=()
if [[ -d "${HOST_RUNNER_DIR}" ]]; then
  RUNNER_BASE="$(basename "${HOST_RUNNER_DIR}")"
  RUNNER_TAR_ARGS=(-C "$(dirname "${HOST_RUNNER_DIR}")" "${RUNNER_BASE}")
fi

cat > "${STAGE}/manifest.txt" <<EOF
created=${TS}
pod_name=${POD_NAME}
podman_user=${PODMAN_USER}
host_data_dir=${HOST_DATA_DIR}
host_runner_dir=${HOST_RUNNER_DIR}
config_volume=${CONFIG_VOLUME}
image=${IMAGE}
compression=zstd level ${ZSTD_LEVEL} threads ${ZSTD_THREADS} ${ZSTD_LONG}
encryption=age
EOF

if [[ -n "${AGE_RECIPIENT}" ]]; then
  AGE_ARGS=(-r "${AGE_RECIPIENT}" -o "${OUT}")
elif [[ -n "${AGE_RECIPIENTS_FILE}" ]]; then
  AGE_ARGS=(-R "${AGE_RECIPIENTS_FILE}" -o "${OUT}")
else
  AGE_ARGS=(-p -o "${OUT}")
fi

log "Creating encrypted archive: ${OUT}"
tar -cf - \
  -C "${DATA_PARENT}" "${DATA_BASE}" \
  "${RUNNER_TAR_ARGS[@]}" \
  -C "${STAGE}" config manifest.txt \
  | zstd -T"${ZSTD_THREADS}" -"${ZSTD_LEVEL}" "${ZSTD_LONG}" "${ZSTD_EXTRA[@]}" -c \
  | age "${AGE_ARGS[@]}"

sha256sum "${OUT}" > "${SHA}"

trap cleanup EXIT
restart_if_needed

log "Applying retention: delete encrypted backups older than ${KEEP_DAYS} days"
find "${BACKUP_ROOT}" -maxdepth 1 -type f -name 'gitea-pod-*.tar.zst.age' -mtime +"${KEEP_DAYS}" -delete
find "${BACKUP_ROOT}" -maxdepth 1 -type f -name 'gitea-pod-*.tar.zst.age.sha256' -mtime +"${KEEP_DAYS}" -delete

log "Backup completed"
printf 'Encrypted backup: %s\n' "${OUT}"
printf 'Checksum:         %s\n' "${SHA}"
