#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
BUNDLE_DIR="$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd -P)"
CONFIG_FILE="${CONFIG_FILE:-${BUNDLE_DIR}/config.env}"

if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck disable=SC1090
  . "${CONFIG_FILE}"
fi

: "${BACKUP_CRON_SCHEDULE:=17 3 * * *}"
: "${BACKUP_CRON_FILE:=/etc/cron.d/gitea-podman-backup}"
: "${BACKUP_CRON_LOG:=/var/log/gitea-podman-backup.log}"
: "${BACKUP_CRON_USER:=root}"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
shell_quote() { printf '%q' "$1"; }

[[ "$(id -u)" -eq 0 ]] || fail "Run as root"
[[ -f "${SCRIPT_DIR}/scheduled_backup.sh" ]] || fail "Missing scheduled backup script"

command="cd $(shell_quote "${BUNDLE_DIR}") && CONFIG_FILE=$(shell_quote "${CONFIG_FILE}") ./scripts/scheduled_backup.sh >> $(shell_quote "${BACKUP_CRON_LOG}") 2>&1"

install -d -m 0755 "$(dirname "${BACKUP_CRON_FILE}")"
{
  printf '# Installed by gitea-rootless-podman-kit. Edit config.env, not this file.\n'
  printf 'SHELL=/bin/bash\n'
  printf 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n\n'
  printf '%s %s /bin/bash -lc %s\n' "${BACKUP_CRON_SCHEDULE}" "${BACKUP_CRON_USER}" "$(shell_quote "${command}")"
} > "${BACKUP_CRON_FILE}"
chmod 0644 "${BACKUP_CRON_FILE}"

printf 'Installed cron entry: %s\n' "${BACKUP_CRON_FILE}"
printf 'Schedule: %s\n' "${BACKUP_CRON_SCHEDULE}"
printf 'Log: %s\n' "${BACKUP_CRON_LOG}"
printf 'Command: %s\n' "${command}"
printf '\nMake sure your cron daemon is enabled/running on this host.\n'
