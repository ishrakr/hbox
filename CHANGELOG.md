# Changelog

All notable changes to HBOX. Versions are git tags; servers following the
`stable` channel get the newest one ([Updates](wiki/Updates.md)).

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
