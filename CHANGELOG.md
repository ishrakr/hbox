# Changelog

All notable changes to HBOX. Versions are git tags; servers following the
`stable` channel get the newest one ([Updates](wiki/Updates.md)).

## v1.1.0 (2026-11-15)

### Added
- Optional app **Documents** ([Paperless-ngx](https://docs.paperless-ngx.com)
  3.4.2): `sudo hbox apps enable paperless`, at `https://<server>:7443`. Text
  recognition and full-text search for scans and PDFs; upload in the browser,
  from the Paperless mobile apps, or by dropping files into
  `/DATA/apps/paperless/consume`. Signs in with the HBOX administrator login.
  Its documents, settings and database are backed up and restored with the
  rest.
- Optional apps can declare generated `secrets`, a PostgreSQL `database`
  (dumped before each backup, loaded on restore, raw folder not backed up),
  `exclude` folders and a `setup.sh` run after each start.

### Changed
- Dashboard: CPU, memory, network, storage and disk health are one slim
  status line instead of four tiles with charts. Values turn orange or red
  only when they need attention; a disk with problems adds a message saying
  what to do. Details (averages, peaks, totals, drive models and
  temperatures) appear on hover or tap.

### Fixed
- `hbox start`, `stop` and `restart` include optional apps.
- A restore stops optional apps first and starts them again afterwards.
- Enabling or disabling an app updates the backup plan right away, instead of
  at the next update.

## v1.0.2 (2026-11-15)

### Added
- Dashboard: **Memory** tile with memory in use, a one-hour chart, and swap
  when it is in use.
- **Disk health** (SMART) for the server and backup drives: shown in the
  Storage tile (healthy, showing wear, failing, temperature) and checked by
  `hbox doctor`, which says what to do. Read at most hourly; a sleeping backup
  disk is never woken. Installs `smartmontools` (patch `0001` on existing
  servers).

### Changed
- Photos: Immich uses its optimized machine-learning models
  (`MACHINE_LEARNING_MODEL_REVISION=v2`): faster and lighter, with identical
  results, so nothing is processed again. They download once on first use
  (about 1 GB). Set `IMMICH_ML_MODEL_REVISION=main` in `.env` to go back.

## v1.0.1 (2026-11-15)

### Added
- Dashboard: **CPU** tile with current use, a one-hour chart, the hour's
  average, cores and load.
- Dashboard: **Network** tile with current download and upload speed, a
  one-hour chart and the amount transferred in that hour. Only the server's
  network ports are counted, not traffic between apps inside it.
- `hbox backup disk` takes over a backup disk that was mounted outside HBOX
  (for example set up before HBOX): it moves it to `/mnt/hbox-backup` and
  replaces its old `/etc/fstab` line, keeping the backups on it as they are.
  Eject, "disk connected" checks and automatic remounting then apply.
- GNU GPL v2 license.

### Changed
- Photos: Immich **v3.4.1** (from v2.7.5). Major upgrade: the mobile apps
  must be v3 too. Immich cannot be downgraded; `hbox update` backs up first.
  See Immich's [v3 migration guide](https://immich.app/blog/v3-migration).

### Fixed
- The HBOX certificate download (`/hbox-ca.crt`) is no longer cached by
  browsers, so a new certificate is never hidden by an old copy.

## v1.0.0 (2026-11-15)

First release: Photos (Immich), Files (Nextcloud), Admin (Dockge) and Backups
(Backrest with restic) behind nginx on their own HTTPS ports, a dashboard with
an update button, backup disk setup, git-based updates with patches and
rollback, optional Tailscale and optional apps, and migration from the
earlier hbox-apps deployment.
