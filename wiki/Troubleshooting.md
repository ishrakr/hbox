# Troubleshooting

Start with:

```sh
sudo hbox doctor
```

It checks Docker, disks, the certificate, every app and backups, and prints
the fix for each problem.

## Browser warns about the certificate

The device doesn't trust HBOX's CA yet: see
[First steps](First-steps.md#2-trust-hboxs-https). If it trusted it before,
the name you're using may be missing from the certificate:
`sudo hbox certs names`, then add it to `HBOX_EXTRA_NAMES` (see
[Addresses](Addresses-and-HTTPS.md#other-names)).

## `hbox.local` doesn't open

- Use the IP address (`sudo hbox status` lists it).
- Some Android versions and guest Wi-Fi networks don't support `.local`.
  Add the names to your router's DNS, or use the IP.
- On the server: `systemctl status hbox-mdns avahi-daemon`.

## An app doesn't respond

```sh
sudo hbox status              # container states and health
sudo hbox logs immich-server  # or nextcloud, hbox-nginx, hbox-dockge, ...
sudo hbox restart
```

Or use Admin to restart a single stack. Photos needs about a minute after
starting; Nextcloud longer after an upgrade.

## "Access through untrusted domain" in Files

Nextcloud doesn't know the address you used. Add it to `HBOX_EXTRA_NAMES`,
then `sudo hbox certs renew` and `sudo hbox update`.

## Backups

| Symptom | Fix |
| --- | --- |
| Dashboard: a disk "showing wear" or "failing" | The drive itself reports problems (bad sectors, worn out). Copy what matters now and plan to replace it. Details: `sudo smartctl -a /dev/sdX`; backup disk: [restore onto a new disk](Restore.md) |
| Dashboard: "Backup disk not connected" | Plug in the disk; the next backup mounts it. Check with `sudo hbox backup status` |
| "Last backup failed" | Open Backups (`:6443`) for the error, or `journalctl -u hbox-backrest` |
| Backups page doesn't load | `sudo hbox backup backrest-sync` |
| Disk not listed by `hbox backup disk` | `sudo hbox backup disk list`; check `lsblk`. Disks under 8 GB and disks the server runs from are not offered |
| "repository is already locked" | A backup was interrupted; Backrest unlocks stale locks itself. Otherwise `sudo hbox backup restic unlock` |

## Updates

| Symptom | Fix |
| --- | --- |
| "Files tracked by git were changed on this server" | Undo the edits (`sudo git -C /opt/hbox checkout -- <file>`), or keep them in `.env` / `local/` ([Updates](Updates.md#local-changes)) |
| Update failed halfway | Fix the cause shown, then run `sudo hbox update` again; finished steps are kept |
| Problem after an update | `sudo hbox rollback` |
| Dashboard update failed | `/var/lib/hbox/update.log` |

## Data disk not mounted

Apps refuse to start rather than write to the system disk. Mount the disk
(check `/etc/fstab`), then `sudo hbox start`.

## Getting help

Open an issue at [github.com/ishrakr/hbox](https://github.com/ishrakr/hbox/issues)
with the output of `sudo hbox doctor` and `sudo hbox version`. Remove any
passwords first.
