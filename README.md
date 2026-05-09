# Gitea Rootless Podman Kit

Portable scripts to run a single-node Gitea instance in a rootless Podman pod, back it up as encrypted archives, and restore it on another machine.

## Scope

This kit handles:

- rootless Podman pod + Gitea container
- SQLite (inside Gitea data)
- host bind mount for Gitea data
- Podman volume for `/etc/gitea`
- encrypted backups (`age` + `zstd`)
- restore from encrypted backups
- OpenRC/systemd boot integration

This kit does not handle:

- TLS/reverse proxy
- PostgreSQL/MySQL
- external object storage
- provisioning a separate actions runner service

## Repository Layout

```text
.
├── backups/                 # staged encrypted backups (gitignored by default)
├── keys/                    # public age recipient files
├── openrc/                  # OpenRC service template
├── scripts/                 # operational scripts
├── systemd/                 # systemd service templates
├── config.example.env       # copy to config.env
└── config.env               # local machine config (gitignored)
```

## Host Prerequisites

Install packages as root. Names vary by distro.

Debian/Ubuntu example:

```bash
apt-get update
apt-get install -y podman age zstd curl uidmap slirp4netns fuse-overlayfs
```

Gentoo example:

```bash
emerge --ask app-containers/podman app-crypt/age app-arch/zstd net-misc/curl app-containers/slirp4netns sys-fs/fuse-overlayfs
```

Scripts also require: `bash`, `tar`, `su`.

Create the service account (default `git`) if needed:

```bash
getent group git >/dev/null || groupadd -r git
id git >/dev/null 2>&1 || useradd -r -m -d /var/lib/git -s /bin/bash -g git git
```

## Initial Setup

From this bundle directory:

```bash
cp config.example.env config.env
# edit config.env
./scripts/check_prereqs.sh
```

Important defaults in `config.env`:

```bash
PODMAN_USER="git"
PODMAN_GROUP="git"
PODMAN_XDG_RUNTIME_DIR="/run/podman-gitea"
GITEA_BASE_DIR="/srv/gitea"
HOST_DATA_DIR="${GITEA_BASE_DIR}/var/lib/gitea"
HOST_RUNNER_DIR="${GITEA_BASE_DIR}/var/lib/act_runner"
BACKUP_ROOT="${GITEA_BASE_DIR}/backups"
CONFIG_VOLUME="gitea-config"
HTTP_BIND="127.0.0.1"
HTTP_HOST_PORT="3000"
SSH_BIND="127.0.0.1"
SSH_HOST_PORT="2222"
FRESH_ROOT_URL="http://127.0.0.1:3000/"
```

## Encryption Key Setup

Generate age keys as a normal user (not root):

```bash
mkdir -p ~/.config/gitea-backup
chmod 700 ~/.config/gitea-backup
age-keygen -o ~/.config/gitea-backup/gitea-backup.agekey
age-keygen -y ~/.config/gitea-backup/gitea-backup.agekey > ~/.config/gitea-backup/gitea-backup.recipient
chmod 600 ~/.config/gitea-backup/gitea-backup.agekey
chmod 644 ~/.config/gitea-backup/gitea-backup.recipient
```

Copy public recipient into this repo:

```bash
cp ~/.config/gitea-backup/gitea-backup.recipient keys/gitea-backup.recipient
```

`./scripts/create_and_stage_backup.sh` uses `keys/gitea-backup.recipient` by default.

If the private key is lost, encrypted backups cannot be restored.

## Script Reference

Every operation below follows the same format: script path + command to run.

### `scripts/check_prereqs.sh`

Purpose: preflight check for required commands, users/groups, rootless podman readiness, service-manager detection.

Run:

```bash
./scripts/check_prereqs.sh
```

### `scripts/create_fresh_gitea_pod.sh`

Purpose: create empty data dir, write starter `app.ini`, create pod/container for web installer.

Run as root:

```bash
./scripts/create_fresh_gitea_pod.sh
```

Key flags:

- `FORCE_CREATE=1` replaces existing pod/data/volume.
- `SKIP_PULL=1` skips image pull.

### `scripts/restore_gitea_pod.sh`

Purpose: decrypt backup, restore data/config/runner, recreate pod/container, regenerate hooks/keys.

Run as root:

```bash
BACKUP_ARCHIVE=./backups/gitea-pod-YYYY-MM-DD_HHMMSS.tar.zst.age \
AGE_IDENTITY=/path/to/private/gitea-backup.agekey \
FORCE_RESTORE=1 \
./scripts/restore_gitea_pod.sh
```

Key flags:

- `FORCE_RESTORE=1` required when target pod/data already exists.
- `SKIP_PULL=1` skips image pull.

### `scripts/create_and_stage_backup.sh`

Purpose: consistent backup (stop/start pod), encrypt archive, stage latest archive + checksum into local `backups/`.

Run as root:

```bash
./scripts/create_and_stage_backup.sh
```

Key flags:

- `ZSTD_LEVEL=19` overrides compression level.
- retention in `BACKUP_ROOT` uses `KEEP_DAYS`.

### `scripts/install_boot_service.sh`

Purpose: install and start boot service for OpenRC or systemd.

Run as root:

```bash
./scripts/install_boot_service.sh
```

Key flags:

```bash
SERVICE_MANAGER=openrc ./scripts/install_boot_service.sh
SERVICE_MANAGER=systemd ./scripts/install_boot_service.sh
```

### `scripts/cron_private_fork_backup.sh`

Purpose: run backup, stage encrypted files in repo, commit, and optionally push to private remote.

Run as root:

```bash
./scripts/cron_private_fork_backup.sh
```

Key config in `config.env`:

```bash
PRIVATE_BACKUP_GIT_USER="your-login-user"
PRIVATE_BACKUP_GIT_GROUP="your-login-group"
PRIVATE_BACKUP_PUSH="1"
PRIVATE_BACKUP_GIT_REMOTE="origin"
PRIVATE_BACKUP_GIT_BRANCH="main"
PRIVATE_BACKUP_KEEP_REPO_BACKUPS="14"
```

## Workflows

### Fresh install (no existing backup)

Run in order:

```bash
./scripts/check_prereqs.sh
sudo ./scripts/create_fresh_gitea_pod.sh
sudo ./scripts/install_boot_service.sh
```

Then open `FRESH_ROOT_URL`, finish the web installer, and create the first backup:

```bash
sudo ./scripts/create_and_stage_backup.sh
```

### Restore from encrypted backup

Required inputs:

- encrypted archive (`.tar.zst.age`)
- matching private age identity (`.agekey`)

Run in order:

```bash
./scripts/check_prereqs.sh
sudo BACKUP_ARCHIVE=./backups/gitea-pod-YYYY-MM-DD_HHMMSS.tar.zst.age \
  AGE_IDENTITY=/path/to/private/gitea-backup.agekey \
  FORCE_RESTORE=1 \
  ./scripts/restore_gitea_pod.sh
sudo ./scripts/install_boot_service.sh
```

If hostname/public URL/SMTP/proxy settings changed, update restored `app.ini` and restart pod.

## Backup Inspection

List archive contents:

```bash
age -d -i ~/.config/gitea-backup/gitea-backup.agekey backups/gitea-pod-YYYY-MM-DD_HHMMSS.tar.zst.age | zstd -d | tar -tf -
```

Check DB path exists:

```bash
age -d -i ~/.config/gitea-backup/gitea-backup.agekey backups/gitea-pod-YYYY-MM-DD_HHMMSS.tar.zst.age | zstd -d | tar -tf - | grep '/data/gitea.db$'
```

Verify checksum:

```bash
sha256sum -c backups/gitea-pod-YYYY-MM-DD_HHMMSS.tar.zst.age.sha256
```

## Service Status Checks

```bash
# OpenRC
rc-service podman-gitea status

# systemd
systemctl status podman-gitea.service

# HTTP probe
curl -I http://127.0.0.1:3000/
```

## Private Cron Example

```cron
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

17 3 * * * root cd /path/to/private/gitea-rootless-podman-kit && ./scripts/cron_private_fork_backup.sh >> /var/log/gitea-private-backup.log 2>&1
```

## Public vs Private Files

Safe for public template repo:

- `.gitignore`
- `README.md`
- `config.example.env`
- `keys/*.recipient`
- `openrc/`
- `scripts/`
- `systemd/`

Keep private:

- `config.env`
- `*.agekey`
- encrypted backups unless intentionally stored in private infrastructure
- raw `app.ini`
- raw Gitea data directories / `.db` / `.sqlite`
- unencrypted archives (`.tar`, `.tar.zst`, etc.)

Backups are gitignored by default:

```text
backups/*
!backups/.gitkeep
```

Force-add encrypted backups only when intentional in private storage:

```bash
git add -f backups/gitea-pod-YYYY-MM-DD_HHMMSS.tar.zst.age backups/gitea-pod-YYYY-MM-DD_HHMMSS.tar.zst.age.sha256
git commit -m "Add encrypted Gitea backup"
```

## Restore Drill Checklist

Periodically restore to a separate machine/path and confirm:

- login works
- repositories are visible
- clone works
- push works
- runner state is restored or intentionally re-registered
