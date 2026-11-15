# Server layout

## Folders

| Path | Holds |
| --- | --- |
| `/opt/hbox` | Git checkout of HBOX, plus `.env` and `certs/` |
| `/opt/hbox/local` | This server's own apps and dashboard links (ignored by git) |
| `/etc/hbox` | Secrets: credentials, CA, backup settings, Backups configuration |
| `/var/lib/hbox` | State: patches done, update and backup status, dashboard status, generated nginx files |
| `/DATA` | All app data (`DATA_ROOT`) |
| `/mnt/hbox-backup` | Backup disk, when one is set up |
| `/usr/local/bin/hbox` | Link to `/opt/hbox/scripts/hbox` |
| `/usr/local/bin/restic`, `backrest` | Backup tools (pinned versions, checksum-verified) |

## Data

```text
/DATA/
  immich/upload/        photos and videos
  immich/pgdata/        Photos database (PostgreSQL 14)
  immich/model-cache/   machine-learning models (re-downloaded if lost)
  nextcloud/data/       users' files
  nextcloud/config/     Nextcloud configuration
  nextcloud/pgdata/     Files database (PostgreSQL 18)
  dockge/               Admin settings
  tailscale/            remote-access identity
  apps/<name>/          optional apps
  restores/             files restored from Backups
  .hbox-backup/         database dumps made before each backup
```

## Containers

Each part is a separate Docker Compose stack, so restarting one never affects
another. They share the `hbox-frontend` network.

| Stack | Containers |
| --- | --- |
| `hbox-core` | `hbox-nginx`: HTTPS for every app, and the dashboard |
| `hbox-photos` | `immich-server`, `immich-machine-learning`, `immich_redis`, `immich-postgres` |
| `hbox-files` | `nextcloud`, `nextcloud-db` |
| `hbox-dockge` | `hbox-dockge` (Admin) |
| `hbox-tailscale` | `hbox-tailscale` (when enabled) |
| `hbox-app-<name>` | each enabled optional app |

nginx is the stock image; its configuration (`config/nginx`) and the dashboard
(`config/dashboard`) are mounted read-only from the checkout.

Backups (Backrest) runs on the host, not in a container, because it reads all
data and dumps the databases. It listens only on Docker's bridge address;
nginx serves it on port 6443.

## System services

| Unit | Runs |
| --- | --- |
| `hbox-backrest.service` | Backups (Backrest); schedules backups, checks and pruning |
| `hbox-update.timer` | Daily 04:30: update check (and install, with `HBOX_AUTO_UPDATE=1`) |
| `hbox-maintenance.timer` | Weekly: certificate renewal, Nextcloud proxy settings |
| `hbox-status.timer` | Every minute: dashboard status |
| `hbox-dashboard.path` | Runs dashboard requests (update check, update) |
| `hbox-mdns.service` | Announces the `.local` names |

Timers catch up after the server was off (`Persistent=true`).
