# Apps

| App | Address | Software |
| --- | --- | --- |
| Dashboard | `https://hbox.local` | HBOX's start page ([Dashboard](Dashboard.md)) |
| Photos | `:2443` or `https://photos.local` | [Immich](https://immich.app) |
| Files | `:3443` or `https://files.local` | [Nextcloud](https://nextcloud.com) |
| Admin | `:5443` or `https://admin.local` | [Dockge](https://github.com/louislam/dockge) |
| Backups | `:6443` | [Backrest](https://github.com/garethgeorge/backrest) with [restic](https://restic.net) |
| Remote access | optional | [Tailscale](https://tailscale.com) |

Ports work on every address of the server; see
[Addresses and HTTPS](Addresses-and-HTTPS.md).

## Photos (Immich)

Photo and video library with automatic phone backup, face recognition and
search. Log in with the administrator **e-mail** and password
(`sudo hbox credentials`), then invite family members under
Administration > Users.

Data: `/DATA/immich/upload` (originals) and its PostgreSQL database.

## Files (Nextcloud)

Files, calendars and contacts, with desktop and phone sync apps. Log in with
the administrator **user name**. Calendar and contacts sync (CalDAV/CardDAV)
use `https://files.local` or `https://<address>:3443`.

Data: `/DATA/nextcloud/data` (users' files) and its PostgreSQL database.

Run Nextcloud commands with:

```sh
sudo docker exec -u abc nextcloud php /app/www/public/occ <command>
```

## Admin (Dockge)

Start, stop, restart, view logs and open terminals for each part of HBOX.
Stacks: **hbox-core** (proxy and dashboard), **hbox-photos**, **hbox-files**,
**hbox-tailscale**, and one per [optional app](Optional-apps.md).

Prefer `sudo hbox update` over Dockge's *Update* button: it backs up first and
keeps app versions in step with HBOX.

Anyone who can log in to Admin controls the server (Docker access is root
access). See [Security](Security.md).

## Backups (Backrest)

Runs, schedules and manages the encrypted backups: back up now, history,
browse and restore files, retention and notifications. Appears once backups
are set up. See [Backups](Backups.md).

## App versions

Versions are pinned in HBOX's compose files and change with
[HBOX updates](Updates.md), after testing. To hold an app at a version of your
own, set it in `/opt/hbox/.env` ([Configuration](Configuration.md#app-versions)).
