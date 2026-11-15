# Configuration

Settings are in `/opt/hbox/.env` (root-only). After editing, run
`sudo hbox restart` (or `sudo hbox update` for names and apps). Every stack
links to this one file, so Admin (Dockge) sees the same settings.

| Setting | Default | Meaning |
| --- | --- | --- |
| `DATA_ROOT` | `/DATA` | Photos, files, databases and app state |
| `TZ` | server's zone | Time zone for all apps |
| `PUID` / `PGID` | `1000` | Owner of Nextcloud's files on disk |
| `HBOX_REF` | `main` | What updates follow ([Updates](Updates.md#release-channels)) |
| `HBOX_AUTO_UPDATE` | `0` | `1`: install updates automatically after the daily check |
| `HBOX_REPO` | GitHub | Where updates come from |
| `HBOX_APPS` | | Enabled optional apps (managed by `hbox apps`) |
| `HBOX_MDNS` | `1` | Announce the `.local` names |
| `HBOX_EXTRA_NAMES` | | Extra names/IPs for HTTPS and Nextcloud, comma-separated |
| `APP_BIND_ADDRESS` | `127.0.0.1` | `0.0.0.0` also exposes Photos' and Files' own ports (2283, 8443) to the network, bypassing HBOX's HTTPS; not recommended |
| `HBOX_ENABLE_TAILSCALE`, `TS_*` | off | [Remote access](Remote-access.md) |
| `IMMICH_DB_PASSWORD`, `NEXTCLOUD_DB_PASSWORD` | generated | Database passwords; changing them here doesn't change an existing database |

## Storage

Put `DATA_ROOT` on your largest, most reliable disk, mounted at boot
(`/etc/fstab` with `nofail`). HBOX never creates missing data folders when
starting, so an unmounted disk makes apps fail loudly instead of quietly
filling the system disk.

To move existing data:

```sh
sudo hbox stop
sudo rsync -aHAX /DATA/ /srv/hbox/
# set DATA_ROOT=/srv/hbox in /opt/hbox/.env
sudo hbox start
```

## App versions

App versions come from HBOX's compose files and change with updates. To hold
an app at a version of your choice, set it in `.env`:

```sh
IMMICH_VERSION=v3.4.1
NEXTCLOUD_IMAGE=lscr.io/linuxserver/nextcloud:35.0.3
DOCKGE_IMAGE=louislam/dockge:1.5.0
TAILSCALE_IMAGE=tailscale/tailscale:v1.104.7
```

Photos uses Immich's optimized machine-learning models
(`IMMICH_ML_MODEL_REVISION=v2`: faster, less memory, same results). Set it to
`main` to use the original ones.

Remove the line to follow HBOX again. Before changing versions yourself, read
the app's release notes: Nextcloud only moves **one major version at a time**
(e.g. 34 → 35), and PostgreSQL major versions are never upgraded
automatically.

## Secrets

| File | Holds |
| --- | --- |
| `/opt/hbox/.env` | Settings and database passwords (mode 600) |
| `/etc/hbox/credentials` | Administrator login |
| `/etc/hbox/ca/` | HTTPS certificate authority |
| `/etc/hbox/restic-password`, `backup.env` | Backup repository password and credentials |
| `/etc/hbox/backrest/` | Backups (Backrest) configuration |

All are root-only and included in backups, except the repository password
(it must never sit inside its own backup; keep it off the server).
