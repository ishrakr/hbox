# Backups

HBOX backs up with [restic](https://restic.net): encrypted, deduplicated
(unchanged photos are stored once) and verifiable. Backups are run and managed
in **Backups** ([Backrest](https://github.com/garethgeorge/backrest)) at
`https://<server>:6443`, with the HBOX administrator login.

To get files back, see [Restore](Restore.md).

## Backup disk

Plug in a USB disk (or add a second internal disk) and run:

```sh
sudo hbox backup disk
```

```text
  #   DISK           SIZE     USB   MODEL              STATE
  1   /dev/sda       2TB      yes   WD Elements        empty
  2   /dev/nvme0n1   512GB    -     Samsung SSD        in use by this server
```

| Disk | What happens |
| --- | --- |
| Empty | You type its name (e.g. `sda`) to confirm; HBOX partitions and formats it (ext4) |
| Has data | Nothing is changed unless you choose `--format` (erase) or `--keep` (keep its files; backups go in a folder `hbox/`; ext4, xfs, btrfs or exFAT only) |
| Has HBOX backups | Used as it is; you enter their password ([new server](Restore.md#on-a-new-server)) |
| Holds this server's backups, mounted elsewhere (e.g. set up before HBOX) | Taken over as it is: moved to `/mnt/hbox-backup`, its old `/etc/fstab` line replaced; the backups stay where they are on the disk |
| Runs this server | Refused |

HBOX mounts the disk at `/mnt/hbox-backup` (by UUID, with `nofail`, so the
server boots without it), creates the encrypted repository, starts Backups and
prints the repository password once.

> **Store the repository password off the server.** Show it again with
> `sudo hbox backup password`.

Non-interactive: `sudo hbox backup disk /dev/sda --format --yes`.

### Unplugging

```sh
sudo hbox backup disk eject     # waits for running work, then unmounts
```

While the disk is away, backups don't run and nothing is written to the
server's own disk. The dashboard and `hbox doctor` show "backup disk not
connected". After plugging it back in, the next backup mounts it again.

## NAS or cloud

```sh
# Over SSH (set up key login for root first)
sudo hbox backup setup --repo sftp:backup@nas.local:/volume1/hbox

# Backblaze B2
sudo hbox backup setup --repo b2:my-bucket:hbox \
    --env B2_ACCOUNT_ID=... --env B2_ACCOUNT_KEY=...

# Amazon S3 or compatible (Wasabi, MinIO, ...)
sudo hbox backup setup --repo s3:s3.amazonaws.com/my-bucket/hbox \
    --env AWS_ACCESS_KEY_ID=... --env AWS_SECRET_ACCESS_KEY=...

# A repository that already exists (asks for its password)
sudo hbox backup setup --repo ... --existing     # or --password-file FILE
```

Any [restic repository type](https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html)
works. A second copy elsewhere (3-2-1 rule) can be added in Backups: **Add
Repo**, then **Add Plan** with the same paths.

## Managing backups

| Task | In Backups |
| --- | --- |
| Back up now | Plans > hbox > **Backup Now** (or `sudo hbox backup run`) |
| History, sizes, errors | Dashboard and the plan's history |
| Browse, restore, download files | Plans > hbox > a backup > browse |
| Schedule | Plans > hbox > Edit > Schedule (default daily 03:00) |
| How many to keep | Plans > hbox > Edit > Retention (default 7 daily, 4 weekly, 12 monthly, 2 yearly) |
| Notifications | Plans > hbox > Edit > Hooks: e-mail (Shoutrrr), ntfy, Gotify, Discord, Slack, Telegram, Healthchecks |
| Integrity check, prune | Repositories > hbox (both also run weekly) |

HBOX keeps four things of the `hbox` plan in line with the server: the paths,
the database-dump hooks, the repository and the login. Everything else you
change in Backups is kept, including across updates.

Tip: add a [Healthchecks.io](https://healthchecks.io) hook to be told when a
backup fails **or doesn't run at all**.

## What is backed up

| Included | Notes |
| --- | --- |
| Photos and Files databases | Dumped with `pg_dumpall` just before each backup. Nextcloud is in maintenance mode only while its database is dumped. |
| Photos (`/DATA/immich/upload`) | Originals and Immich's own database backups |
| Files (`/DATA/nextcloud/config`, `data`) | Users' files, calendars, contacts |
| HBOX configuration | `.env`, certificates, CA, credentials, Backups settings |
| Admin, Tailscale, optional apps | `/DATA/dockge`, `/DATA/tailscale`, `/DATA/apps` |

Not included because they are regenerated: thumbnails, transcoded videos,
Nextcloud previews, the machine-learning model cache. Raw PostgreSQL folders
are deliberately excluded: a copy of a running database is not a reliable
backup, so restores rebuild them from the dumps.

## Command line

```sh
sudo hbox backup status      # disk, last result, number of backups, next run
sudo hbox backup run         # back up now
sudo hbox backup snapshots   # list backups
sudo hbox backup check       # verify the repository and 5% of the data
sudo hbox backup disk list   # attached disks
sudo hbox backup password    # the repository password
sudo hbox backup restic ...  # any restic command on the repository
```

`hbox update` always backs up first.

## Settings file

`/etc/hbox/backup.env` (root-only) holds the repository and its credentials.
`KEEP_*` and `HBOX_BACKUP_NOTIFY_URL` there only seed the plan when Backups is
first set up; afterwards, change them in Backups.
