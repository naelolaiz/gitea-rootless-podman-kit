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
: "${PODMAN_USER:=git}"
: "${PODMAN_GROUP:=git}"
: "${PODMAN_XDG_RUNTIME_DIR:=/run/podman-gitea}"
: "${IMAGE:=docker.gitea.com/gitea:1.26.1-rootless}"
: "${GITEA_BASE_DIR:=/srv/gitea}"
: "${HOST_DATA_DIR:=${GITEA_BASE_DIR}/var/lib/gitea}"
: "${CONFIG_VOLUME:=gitea-config}"

ok() { printf '[OK] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
fail_count=0

check_cmd() {
  if command -v "$1" >/dev/null; then
    ok "found command: $1"
  else
    warn "missing command: $1"
    fail_count=$((fail_count + 1))
  fi
}

check_cmd bash
check_cmd podman
check_cmd age
check_cmd zstd
check_cmd tar
check_cmd curl
check_cmd su

if id "${PODMAN_USER}" >/dev/null 2>&1; then
  ok "service user exists: ${PODMAN_USER}"
else
  warn "service user does not exist: ${PODMAN_USER}"
  fail_count=$((fail_count + 1))
fi

if getent group "${PODMAN_GROUP}" >/dev/null 2>&1; then
  ok "service group exists: ${PODMAN_GROUP}"
else
  warn "service group does not exist: ${PODMAN_GROUP}"
  fail_count=$((fail_count + 1))
fi

if [[ "$(id -u)" -eq 0 ]]; then
  install -d -m 0700 -o "${PODMAN_USER}" -g "${PODMAN_GROUP}" "${PODMAN_XDG_RUNTIME_DIR}" 2>/dev/null || true
fi

if id "${PODMAN_USER}" >/dev/null 2>&1 && command -v podman >/dev/null; then
  if [[ "$(id -u)" -eq 0 ]]; then
    podman_check_cmd=(su -s /bin/bash -c "XDG_RUNTIME_DIR='${PODMAN_XDG_RUNTIME_DIR}' podman info >/dev/null" "${PODMAN_USER}")
  elif [[ "$(id -un)" == "${PODMAN_USER}" ]]; then
    podman_check_cmd=(env "XDG_RUNTIME_DIR=${PODMAN_XDG_RUNTIME_DIR}" podman info)
  else
    podman_check_cmd=()
  fi

  if [[ "${#podman_check_cmd[@]}" -eq 0 ]]; then
    warn "cannot check rootless podman for ${PODMAN_USER}; run as root or as ${PODMAN_USER}"
    fail_count=$((fail_count + 1))
  elif "${podman_check_cmd[@]}" >/dev/null 2>&1; then
    ok "rootless podman works for ${PODMAN_USER}"
  else
    warn "rootless podman check failed for ${PODMAN_USER}"
    fail_count=$((fail_count + 1))
  fi
fi

if [[ -f "${BUNDLE_DIR}/keys/gitea-backup.recipient" ]]; then
  ok "public age recipient found"
else
  warn "no public age recipient at keys/gitea-backup.recipient"
fi

if [[ -d "${BUNDLE_DIR}/backups" ]] && find "${BUNDLE_DIR}/backups" -maxdepth 1 -type f -name '*.tar.zst.age' -print -quit | grep -q .; then
  ok "encrypted backup archive found in backups/"
else
  warn "no encrypted backup archive found in backups/"
fi

if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null; then
  ok "service manager detected: systemd"
elif command -v rc-service >/dev/null && [[ -x /sbin/openrc-run || -x /usr/bin/openrc-run ]]; then
  ok "service manager detected: OpenRC"
else
  warn "no supported service manager detected; backup/restore can still work, boot service install may need manual adaptation"
fi

printf '\nConfig summary:\n'
printf '  POD_NAME=%s\n' "${POD_NAME}"
printf '  PODMAN_USER=%s\n' "${PODMAN_USER}"
printf '  PODMAN_XDG_RUNTIME_DIR=%s\n' "${PODMAN_XDG_RUNTIME_DIR}"
printf '  IMAGE=%s\n' "${IMAGE}"
printf '  HOST_DATA_DIR=%s\n' "${HOST_DATA_DIR}"
printf '  CONFIG_VOLUME=%s\n' "${CONFIG_VOLUME}"

if [[ "${fail_count}" -gt 0 ]]; then
  printf '\n%d required checks failed.\n' "${fail_count}" >&2
  exit 1
fi

printf '\nPreflight passed.\n'
