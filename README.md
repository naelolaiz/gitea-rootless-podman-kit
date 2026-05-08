# Gitea Rootless Podman Kit

Portable scripts for running a small Gitea instance in a rootless Podman pod, with fresh install, encrypted backup, restore, cron automation, and OpenRC/systemd boot integration.

This kit targets a simple single-node deployment:

- Gitea runs in the official rootless container image.
- SQLite is the Gitea database.
- Gitea data is a host bind mount.
- `/etc/gitea` is a Podman named volume.
- Backups are encrypted with `age` and compressed with `zstd`.
- Boot startup is handled by OpenRC or systemd.

It does not set up TLS, a reverse proxy, PostgreSQL/MySQL, external object storage, or a separate Gitea Actions runner service.

## Choose A Workflow

Fresh install, no previous backup:

```bash
cd public_gitea_recovery_bundle
cp config.example.env config.env
# edit config.env
./scripts/check_prereqs.sh
./scripts/create_fresh_gitea_pod.sh
./scripts/install_boot_service.sh
```

Then open `FRESH_ROOT_URL`, complete the Gitea web installer, and create the first backup.

Restore from an existing encrypted backup:

```bash
cd public_gitea_recovery_bundle
cp config.example.env config.env
# edit config.env
./scripts/check_prereqs.sh

BACKUP_ARCHIVE=./backups/gitea-pod-YYYY-MM-DD_HHMMSS.tar.zst.age \
AGE_IDENTITY=/path/to/private/gitea-backup.agekey \
FORCE_RESTORE=1 \
./scripts/restore_gitea_pod.sh

./scripts/install_boot_service.sh
```

Create an encrypted backup of an existing kit-managed pod:

```bash
cd public_gitea_recovery_bundle
./scripts/create_and_stage_backup.sh
```

Automate encrypted backups into a private fork:

```bash
cd public_gitea_recovery_bundle
./scripts/cron_private_fork_backup.sh
```

## Important Rules

Restore from backup requires both files:

- encrypted backup archive: `backups/gitea-pod-YYYY-MM-DD_HHMMSS.tar.zst.age`
- private age identity: for example `~/.config/gitea-backup/gitea-backup.agekey`

Fresh install does not use a backup. It creates an empty Gitea data directory and starts the web installer.

The private age identity is the critical secret. If it is lost, encrypted backups cannot be recovered.

Backup archives are ignored by Git by default. The public repo is a reusable template; encrypted archives should stay local, off-site, or in an explicitly private storage location.

## Repository Layout

```text
.
├── backups/                 # local/private encrypted backups, ignored by default
├── keys/                    # public age recipient files
├── openrc/                  # OpenRC service template
├── scripts/                 # install, backup, restore, cron helpers
├── systemd/                 # systemd service templates
├── config.example.env       # template copied to config.env
└── config.env               # local machine config, ignored by Git
```

## Install Packages

Run package installation as root. Package names vary by distribution.

Gentoo package example:

```bash
emerge --ask app-containers/podman app-crypt/age app-arch/zstd net-misc/curl app-containers/slirp4netns sys-fs/fuse-overlayfs
```

Debian/Ubuntu package example:

```bash
apt-get update
apt-get install -y podman age zstd curl uidmap slirp4netns fuse-overlayfs
```

Other distributions usually provide packages named `podman`, `age`, `zstd`, `curl`, `uidmap` or `shadow-utils`, `slirp4netns`, and `fuse-overlayfs`.

Git is only required for the private-fork cron workflow.

## Create The Service User

Create or choose the system account that will own rootless Podman state. The default used by this kit is `git`.

Portable Linux example, run as root:

```bash
getent group git >/dev/null || groupadd -r git
id git >/dev/null 2>&1 || useradd -r -m -d /var/lib/git -s /bin/bash -g git git
```

The account is a service account, not a personal login account.

## Configure This Machine

Create the local config file:

```bash
cp config.example.env config.env
```

Edit the important values:

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

`config.env` is ignored by Git because it is machine-local. It may contain local paths, hostnames, ports, and private-fork settings.

Relative paths inside `config.env`, such as `AGE_RECIPIENTS_FILE="./keys/gitea-backup.recipient"`, are resolved relative to this bundle directory by the scripts that need them.

Check the host before creating or restoring the pod:

```bash
./scripts/check_prereqs.sh
```

If rootless Podman fails for `PODMAN_USER`, fix that first. Common causes are missing `newuidmap`/`newgidmap`, missing `/etc/subuid` or `/etc/subgid` entries, or distribution-specific Podman storage/networking setup.

## Age Key Setup

Generate the age identity as a normal user, not root:

```bash
mkdir -p ~/.config/gitea-backup
chmod 700 ~/.config/gitea-backup
age-keygen -o ~/.config/gitea-backup/gitea-backup.agekey
age-keygen -y ~/.config/gitea-backup/gitea-backup.agekey > ~/.config/gitea-backup/gitea-backup.recipient
chmod 600 ~/.config/gitea-backup/gitea-backup.agekey
chmod 644 ~/.config/gitea-backup/gitea-backup.recipient
```

Keep this private and offline if possible:

```text
~/.config/gitea-backup/gitea-backup.agekey
```

The recipient is public and can be committed:

```bash
cp ~/.config/gitea-backup/gitea-backup.recipient keys/gitea-backup.recipient
```

`create_and_stage_backup.sh` uses `keys/gitea-backup.recipient` by default through `AGE_RECIPIENTS_FILE`.

## Fresh Install

Use this when there is no previous backup and you want a new empty Gitea instance.

Run as root from this bundle directory:

```bash
./scripts/create_fresh_gitea_pod.sh
```

What it does:

- creates or validates `PODMAN_XDG_RUNTIME_DIR`
- prepares an empty `HOST_DATA_DIR`
- creates a starter `app.ini` with `INSTALL_LOCK=false`
- creates or reuses the `CONFIG_VOLUME` Podman volume
- creates the Podman pod and Gitea container
- starts Gitea and checks HTTP

If the pod, config volume, or data directory already exists, the script stops unless you explicitly set:

```bash
FORCE_CREATE=1 ./scripts/create_fresh_gitea_pod.sh
```

After the script finishes, open `FRESH_ROOT_URL` and complete the Gitea web installer. Then create the first encrypted backup.

## Create A Backup

Run as root from this bundle directory:

```bash
./scripts/create_and_stage_backup.sh
```

What it does:

- reads `config.env`
- stops the pod if it is running
- exports the `CONFIG_VOLUME` Podman volume
- archives the Gitea data directory
- archives the runner directory if it exists
- compresses with `zstd`
- encrypts with `age`
- writes the backup to `BACKUP_ROOT`
- copies the newest encrypted backup into local `backups/`
- restarts the pod if it was running

Compression defaults:

```text
zstd -T0 -12 --long=27
```

Override compression if needed:

```bash
ZSTD_LEVEL=19 ./scripts/create_and_stage_backup.sh
```

`backup_gitea_pod.sh` applies retention inside `BACKUP_ROOT` using `KEEP_DAYS`. Files copied into this repository's `backups/` directory are ignored by Git unless force-added.

## What The Backup Contains

The encrypted archive contains:

- Gitea data directory, including SQLite DB, repositories, attachments, LFS, packages, sessions, indexers, and generated data
- `config/`, exported from the Podman config volume, including `app.ini`
- runner directory, if `HOST_RUNNER_DIR` exists
- `manifest.txt` with backup metadata

With the default paths, the SQLite database is stored as:

```text
gitea/data/gitea.db
```

With the default paths, repositories are stored as:

```text
gitea/data/gitea-repositories/
```

If `HOST_DATA_DIR` or `HOST_RUNNER_DIR` are customized, the top-level archive directory follows the source directory basename. The restore script detects the Gitea data directory by finding `*/data/gitea.db`.

The backup script stops the pod before archiving so SQLite and repository data are captured consistently.

## Inspect A Backup

List archive contents:

```bash
age -d -i ~/.config/gitea-backup/gitea-backup.agekey backups/gitea-pod-YYYY-MM-DD_HHMMSS.tar.zst.age | zstd -d | tar -tf -
```

Check that the database is present:

```bash
age -d -i ~/.config/gitea-backup/gitea-backup.agekey backups/gitea-pod-YYYY-MM-DD_HHMMSS.tar.zst.age | zstd -d | tar -tf - | grep '/data/gitea.db$'
```

Check that repositories are present:

```bash
age -d -i ~/.config/gitea-backup/gitea-backup.agekey backups/gitea-pod-YYYY-MM-DD_HHMMSS.tar.zst.age | zstd -d | tar -tf - | grep '/data/gitea-repositories/'
```

Verify checksum:

```bash
sha256sum -c backups/gitea-pod-YYYY-MM-DD_HHMMSS.tar.zst.age.sha256
```

## Restore From Backup

Use this when you already have an encrypted backup archive and the matching private age identity.

Prepare local config:

```bash
cp config.example.env config.env
# edit config.env
./scripts/check_prereqs.sh
```

Restore as root:

```bash
BACKUP_ARCHIVE=./backups/gitea-pod-YYYY-MM-DD_HHMMSS.tar.zst.age \
AGE_IDENTITY=/path/to/private/gitea-backup.agekey \
FORCE_RESTORE=1 \
./scripts/restore_gitea_pod.sh
```

What it does:

- decrypts the backup into temporary staging
- restores the Gitea data directory
- restores the runner directory if present
- recreates the `CONFIG_VOLUME` Podman volume contents
- recreates the Podman pod and Gitea container
- checks that HTTP responds
- regenerates Gitea hooks and keys

If the pod or data directory already exists, restore stops unless `FORCE_RESTORE=1` is set.

The restored `app.ini` comes from the backup. If the new machine uses a different hostname, public URL, SSH hostname, SMTP server, or reverse proxy layout, update the restored Gitea config after restore and restart the pod.

## Boot Service

Install boot startup as root:

```bash
./scripts/install_boot_service.sh
```

The installer detects systemd or OpenRC. Override detection if needed:

```bash
SERVICE_MANAGER=openrc ./scripts/install_boot_service.sh
SERVICE_MANAGER=systemd ./scripts/install_boot_service.sh
```

Distribution and service manager are independent. Gentoo may use OpenRC or systemd; Debian and Ubuntu usually use systemd but can be customized.

Manual OpenRC install, if the host uses OpenRC:

```bash
install -m 0755 openrc/podman-gitea /etc/init.d/podman-gitea
install -m 0644 openrc/podman-gitea.conf.d /etc/conf.d/podman-gitea
rc-service podman-gitea start
rc-update add podman-gitea default
```

Manual systemd install is normally unnecessary because `scripts/install_boot_service.sh` renders `systemd/podman-gitea.service.template` with values from `config.env`.

Check status on OpenRC:

```bash
rc-service podman-gitea status
curl -I http://127.0.0.1:3000/
```

Check status on systemd:

```bash
systemctl status podman-gitea.service
curl -I http://127.0.0.1:3000/
```

## Public And Private Files

Safe for the public template repo:

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
- `backups/*.tar.zst.age`, unless intentionally adding them to private storage
- `backups/*.tar.zst.age.sha256`, unless intentionally adding them to private storage
- raw `app.ini`
- raw Gitea data directories
- raw `.db` or `.sqlite` files
- unencrypted `.tar`, `.tar.zst`, or repository directories

Encrypted backups are ignored by default:

```text
backups/*
!backups/.gitkeep
```

If you intentionally store encrypted backups in a private fork, force-add them:

```bash
git add -f backups/gitea-pod-YYYY-MM-DD_HHMMSS.tar.zst.age backups/gitea-pod-YYYY-MM-DD_HHMMSS.tar.zst.age.sha256
git commit -m "Add encrypted Gitea backup"
```

## Automatic Private-Fork Backups

`scripts/cron_private_fork_backup.sh` is optional. It is for private clones only.

What it does:

- creates a consistent encrypted backup
- stages the newest archive under `backups/`
- force-adds the ignored encrypted archive and checksum
- commits them to the private fork
- optionally pushes to the private remote

Configure `config.env`:

```bash
PRIVATE_BACKUP_GIT_USER="your-login-user"
PRIVATE_BACKUP_GIT_GROUP="your-login-group"
PRIVATE_BACKUP_PUSH="1"
PRIVATE_BACKUP_GIT_REMOTE="origin"
PRIVATE_BACKUP_GIT_BRANCH="main"
PRIVATE_BACKUP_KEEP_REPO_BACKUPS="14"
```

Run once manually as root:

```bash
./scripts/cron_private_fork_backup.sh
```

Example `/etc/cron.d/gitea-private-backup`:

```cron
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

17 3 * * * root cd /path/to/private/gitea-rootless-podman-kit && ./scripts/cron_private_fork_backup.sh >> /var/log/gitea-private-backup.log 2>&1
```

Cron runs as root because the backup needs to stop/start the pod and read service data. Git commits and pushes are performed as `PRIVATE_BACKUP_GIT_USER`, which defaults to the owner of the repository directory.

Before enabling `PRIVATE_BACKUP_PUSH=1`, configure Git identity and push credentials for `PRIVATE_BACKUP_GIT_USER`:

```bash
su -s /bin/bash -c 'git config --global user.name "Gitea Backup" && git config --global user.email "gitea-backup@example.invalid"' your-login-user
su -s /bin/bash -c 'cd /path/to/private/gitea-rootless-podman-kit && git push --dry-run origin main' your-login-user
```

GitHub normal Git has a hard file-size limit for large blobs. If encrypted backups are larger than that, use Git LFS, release assets, another private remote, or non-Git backup storage. `PRIVATE_BACKUP_KEEP_REPO_BACKUPS` only prunes files from the current working tree; it does not remove old backup blobs from Git history.

## Restore Drill

A backup should be treated as unproven until a restore has been tested. Periodically restore to another machine or alternate data path and confirm:

- login works
- repositories are visible
- clone works
- push works
- actions/runner setup is restored or intentionally re-registered
