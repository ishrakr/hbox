# Migrating from hbox-apps

HBOX replaces `hbox-apps`, `hbox-homepage` and `hbox-nginx`. The migration
adopts your data **in place**: the same `/DATA` folders, database versions
and database passwords. Nothing is copied or converted.

| Before | After |
| --- | --- |
| 5 separate compose projects | One stack per app, managed by `hbox` |
| Homepage container | Dashboard served by nginx |
| Custom nginx image (host network, key in the image) | Stock nginx, configuration from git, key on the server |
| Apps on `:8443`, `:2283` | Photos `:2443`, Files `:3443`, Admin `:5443` |
| Hand-made backups (if any) | Backups (Backrest) with database dumps |

## Before you start

1. **Back up.** At least dump both databases:

   ```sh
   umask 077; mkdir -p /root/pre-hbox
   docker exec immich-postgres pg_dumpall --clean --if-exists -U immich > /root/pre-hbox/immich.sql
   docker exec nextcloud-db pg_dumpall --clean --if-exists -U nextcloud > /root/pre-hbox/nextcloud.sql
   ```

   Ideally also copy `/DATA` to another disk while the apps are stopped.

2. **Check versions.** HBOX ships Immich `v3.4.1` and Nextcloud `35.0.3`.
   Check Nextcloud with
   `docker exec -u abc nextcloud php /app/www/public/occ status`. If it is
   more than one major version below 35, the migration stops and says which
   version to step through first (`NEXTCLOUD_IMAGE`).

3. **Database passwords.** The old compose files used `immich` and
   `nextcloud`; `--migrate` assumes those. If you changed them, pass
   `--immich-db-password` and `--nextcloud-db-password`.

## Migrate

From the LAN (an SSH session over the old Tailscale container also works: it
is left running):

```sh
curl -fsSL https://raw.githubusercontent.com/ishrakr/hbox/main/install.sh | sudo bash -s -- --migrate
```

The installer downloads everything while the old apps keep running, lists the
containers it will replace and asks for confirmation. Then it stops the old
containers (data stays), starts HBOX, configures Nextcloud's trusted domains
and proxies and creates the Admin login. **Photos and Files accounts are
unchanged.** The outage is about two minutes.

It also handles a Dockge-style deployment (`/opt/stacks/*`, `/opt/dockge`):

- `/opt/stacks` and `/opt/dockge` are left on disk, unused; delete them when
  you're happy.
- `avahi-alias@*.local` units are disabled; HBOX announces the names itself.
- A hand-made `hbox-backup` restic job keeps running as `hbox-legacy-backup`
  until you adopt its repository (the installer prints the command):

  ```sh
  sudo hbox backup setup --existing --repo /mnt/backup/restic --password-file /root/.restic-pass
  ```

  This stops the old job; its snapshots stay and appear in Backups.

## After migrating

1. `sudo hbox doctor`
2. Set up backups if none were adopted: [Backups](Backups.md).
3. Trust HBOX's certificate on each device: `sudo hbox ca`. Until then, the
   Nextcloud apps ask once to accept the new certificate.
4. In the Nextcloud and Immich apps, change addresses that used `:8443` or
   `:2283` to `https://files.local` / `:3443` and `https://photos.local` /
   `:2443`.
5. Move Tailscale to HBOX when convenient (the identity in `/DATA/tailscale`
   is reused):

   ```sh
   docker stop <old-tailscale-container> && docker rm <old-tailscale-container>
   sudo hbox enable tailscale
   ```

The old `hbox-apps` checkout and images can then be deleted.

## Going back

Until an HBOX update upgrades an app's database, the old setup still works
with the same data:

```sh
sudo hbox uninstall --yes                         # keeps all data
cd hbox-apps/immich && docker compose up -d       # and so on for each project
```

After a database upgrade, going back means restoring the pre-migration dumps.
