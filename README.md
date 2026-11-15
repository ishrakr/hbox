# HBOX

A private home server on Ubuntu or Debian: photos, files, backups and remote
access, installed with one command and updated from git.

| App | Address | Software |
| --- | --- | --- |
| Dashboard | `https://hbox.local` | Status and links |
| Photos | `:2443` · `photos.local` | [Immich](https://immich.app) |
| Files | `:3443` · `files.local` | [Nextcloud](https://nextcloud.com) |
| Admin | `:5443` · `admin.local` | [Dockge](https://github.com/louislam/dockge) |
| Backups | `:6443` | [Backrest](https://github.com/garethgeorge/backrest) + [restic](https://restic.net) |
| Remote access | optional | [Tailscale](https://tailscale.com) |

Ports work on any address of the server: `hbox.local`, LAN IP or Tailscale
name.

## Install

Ubuntu 22.04+ or Debian 12+ (amd64/arm64), 4 GB RAM:

```sh
curl -fsSL https://raw.githubusercontent.com/ishrakr/hbox/main/install.sh | sudo bash
```

Then:

1. **Backups:** attach a disk and run `sudo hbox backup disk`. Save the
   printed password off the server.
2. **HTTPS:** trust HBOX's certificate on each device: `sudo hbox ca`.

## Use

```sh
sudo hbox status          # apps, addresses, storage, backups
sudo hbox doctor          # find and fix problems
sudo hbox update          # back up, then update
sudo hbox credentials     # administrator login
hbox help                 # all commands
```

## Documentation

See the [wiki](https://github.com/ishrakr/hbox/wiki) (also in [`wiki/`](wiki/Home.md)):
[installation](wiki/Installation.md), [backups](wiki/Backups.md),
[restore](wiki/Restore.md), [updates](wiki/Updates.md),
[remote access](wiki/Remote-access.md),
[troubleshooting](wiki/Troubleshooting.md).
What changed in each release: [CHANGELOG.md](CHANGELOG.md).

## License

HBOX is licensed under the [GNU General Public License, version 2](LICENSE)
(GPL-2.0-only). The apps it installs (Immich, Nextcloud, Dockge, Backrest,
restic, Tailscale) keep their own licenses.
