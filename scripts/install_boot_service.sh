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
: "${SERVICE_MANAGER:=auto}"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || fail "Run as root"
id "${PODMAN_USER}" >/dev/null || fail "Missing service user: ${PODMAN_USER}"
getent group "${PODMAN_GROUP}" >/dev/null || fail "Missing service group: ${PODMAN_GROUP}"

detect_manager() {
  if [[ "${SERVICE_MANAGER}" != "auto" ]]; then
    printf '%s\n' "${SERVICE_MANAGER}"
    return
  fi
  if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null; then
    printf 'systemd\n'
  elif command -v rc-service >/dev/null && [[ -x /sbin/openrc-run || -x /usr/bin/openrc-run ]]; then
    printf 'openrc\n'
  else
    fail "Could not detect systemd or OpenRC. Set SERVICE_MANAGER=openrc or SERVICE_MANAGER=systemd."
  fi
}

escape_sed_replacement() {
  printf '%s' "$1" | sed 's/[&|]/\\&/g'
}

manager="$(detect_manager)"
INSTALL_BIN="$(command -v install)"
SU_BIN="$(command -v su)"

case "${manager}" in
  openrc)
    install -m 0755 "${BUNDLE_DIR}/openrc/podman-gitea" /etc/init.d/podman-gitea
    {
      printf '# /etc/conf.d/podman-gitea\n'
      printf 'PODMAN_USER="%s"\n' "${PODMAN_USER}"
      printf 'PODMAN_XDG_RUNTIME_DIR="%s"\n' "${PODMAN_XDG_RUNTIME_DIR}"
      printf 'POD_NAME="%s"\n' "${POD_NAME}"
    } > /etc/conf.d/podman-gitea
    chmod 0644 /etc/conf.d/podman-gitea
    rc-service podman-gitea start
    rc-update add podman-gitea default
    ;;
  systemd)
    tmp="$(mktemp)"
    sed \
      -e "s|__PODMAN_USER__|$(escape_sed_replacement "${PODMAN_USER}")|g" \
      -e "s|__PODMAN_GROUP__|$(escape_sed_replacement "${PODMAN_GROUP}")|g" \
      -e "s|__PODMAN_XDG_RUNTIME_DIR__|$(escape_sed_replacement "${PODMAN_XDG_RUNTIME_DIR}")|g" \
      -e "s|__POD_NAME__|$(escape_sed_replacement "${POD_NAME}")|g" \
      -e "s|__INSTALL_BIN__|$(escape_sed_replacement "${INSTALL_BIN}")|g" \
      -e "s|__SU_BIN__|$(escape_sed_replacement "${SU_BIN}")|g" \
      "${BUNDLE_DIR}/systemd/podman-gitea.service.template" > "${tmp}"
    install -m 0644 "${tmp}" /etc/systemd/system/podman-gitea.service
    rm -f "${tmp}"
    systemctl daemon-reload
    systemctl enable --now podman-gitea.service
    ;;
  *)
    fail "Unsupported SERVICE_MANAGER: ${manager}"
    ;;
esac

printf 'Installed boot service using %s.\n' "${manager}"
