# Restore

## Single files

In Backups (`https://<server>:6443`): Plans > hbox > pick a backup > browse
to the file or folder > **Restore** (to `/DATA/restores/Downloads`) or
**Download**.

From the command line:

```sh
sudo hbox backup restic find 'holiday.jpg'
sudo hbox backup restic restore latest --target /DATA/restores \
    --include /DATA/nextcloud/data/alice/files/Documents/report.pdf
```

Then copy the file back, or upload it through the app. After copying into
Nextcloud's folder, let Nextcloud notice it:

```sh
sudo docker exec -u abc nextcloud php /app/www/public/occ files:scan alice
```

## Everything

```sh
sudo hbox backup restore             # latest backup
sudo hbox backup restore 1a2b3c4d    # a specific one (IDs: sudo hbox backup snapshots)
```

This stops HBOX, restores configuration, photos and files, rebuilds both
databases from their dumps, starts HBOX again and tells Nextcloud sync clients
to re-check their files. Anything added since that backup is lost.

The current databases are **kept** as `*.pre-restore-<time>` folders under
`/DATA`; delete them once you're satisfied.

## On a new server

1. [Install HBOX](Installation.md) (the same `--data-root` as before, if you
   can).
2. Connect the backups:
   - backup disk: plug it in and run `sudo hbox backup disk`. It recognizes
     the HBOX backups and asks for their password.
   - NAS or cloud: `sudo hbox backup setup --repo <the same repository> --existing`
3. `sudo hbox backup restore`

The restored `.env` brings back the database passwords and settings, and the
restored certificate authority means devices that trusted the old server trust
the new one. Users, photos and files are as they were at the backup.

## Test your backups

A backup that was never restored is a hope, not a backup. A few times a year,
restore a single file, and check the dashboard's Backups tile. The weekly
integrity check re-reads a random 5% of the stored data.
