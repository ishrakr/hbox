# Command reference

Run as root (`sudo hbox ...`). `hbox help` shows the same list.

## Everyday

| Command | Does |
| --- | --- |
| `hbox status` | Apps, addresses, disk space and backups |
| `hbox doctor` | Checks for problems and says how to fix each |
| `hbox start` / `stop` / `restart` | All apps |
| `hbox logs [container]` | Recent logs of all apps, or follow one (e.g. `nextcloud`) |
| `hbox credentials` | Administrator login created at install |

## Updates and apps

| Command | Does |
| --- | --- |
| `hbox update` | Back up, then install the latest HBOX |
| `hbox update --check` | Show whether a newer version exists, and what changed |
| `hbox update --ref REF` | Follow another branch or tag (`stable`, `v1.2.0`) |
| `hbox update --skip-backup` | Update without backing up first |
| `hbox rollback [VERSION]` | Back to the previous (or given) version |
| `hbox version` | Installed version and what it follows |
| `hbox apps list` | Optional apps |
| `hbox apps enable NAME` / `disable NAME` | Start / stop an optional app (data kept) |

## Backups

| Command | Does |
| --- | --- |
| `hbox backup disk` | Use an attached disk for backups |
| `hbox backup disk /dev/sdX [--format \| --keep] [--yes]` | The same, non-interactively |
| `hbox backup disk list` | Attached disks and whether they can be used |
| `hbox backup disk eject` | Unmount the backup disk so it can be unplugged |
| `hbox backup setup --repo R [--env K=V] [--existing] [--password-file F]` | Use a NAS, cloud or other repository |
| `hbox backup run` | Back up now |
| `hbox backup status` | Disk, last result, number of backups, next run |
| `hbox backup snapshots` | List backups |
| `hbox backup check` | Verify the repository and part of the data |
| `hbox backup restore [ID] [--yes]` | Restore everything (default: latest) |
| `hbox backup password` | Show the repository password |
| `hbox backup restic ARGS` | Any restic command on the repository |
| `hbox backup backrest-sync` | Re-apply HBOX's settings to Backups and restart it |

## Remote access and certificates

| Command | Does |
| --- | --- |
| `hbox enable tailscale [--authkey KEY] [--routes CIDR]` | Turn on remote access |
| `hbox disable tailscale` | Turn it off (identity kept) |
| `hbox certs renew` | Issue a new HTTPS certificate (devices keep trust) |
| `hbox certs names` | Names and IPs the certificate covers |
| `hbox ca` | How to trust HBOX's HTTPS on devices |

## Installation

| Command | Does |
| --- | --- |
| `hbox setup [options]` | Configure and start HBOX (the installer runs this; see [Installation](Installation.md#options)) |
| `hbox uninstall [--yes]` | Remove HBOX's services; keeps data, configuration and backups |

## Used by system services

`hbox maintenance` (weekly), `hbox status-update` (every minute),
`hbox update --auto` (daily), `hbox dashboard-actions`,
`hbox backup hook ...` and `hbox backup backrest-run`. These aren't needed by
hand.
