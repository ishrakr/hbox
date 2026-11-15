# Installation

## Requirements

- Ubuntu 22.04+ or Debian 12+, amd64 or arm64, with systemd
- 4 GB RAM or more (Photos' machine learning needs it)
- A disk with room for your photos and files
- Internet access during installation

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/ishrakr/hbox/main/install.sh | sudo bash
```

The installer:

1. installs Docker Engine, restic, avahi (mDNS) and a few tools;
2. checks out HBOX to `/opt/hbox` from git;
3. generates every password and an HTTPS certificate authority;
4. downloads and starts all apps and creates the administrator accounts;
5. installs the system services and prints the addresses and login.

It takes 5–15 minutes, mostly downloading. Re-running it is safe: an
interrupted install continues where it stopped, and existing settings and data
are reused.

## Options

Pass options after `sudo bash -s --`:

```sh
curl -fsSL https://raw.githubusercontent.com/ishrakr/hbox/main/install.sh |
    sudo bash -s -- --data-root /srv/hbox --admin-user ishrak
```

| Option | Meaning |
| --- | --- |
| `--data-root PATH` | Where photos, files and databases live (default `/DATA`) |
| `--admin-user NAME` | Administrator for Files and Admin (default `admin`) |
| `--admin-email EMAIL` | Administrator for Photos (default `admin@hbox.local`) |
| `--timezone TZ` | e.g. `Europe/Berlin` (default: the server's zone) |
| `--tailscale-authkey KEY` | Turn on [remote access](Remote-access.md) during install |
| `--no-mdns` | Don't announce the `.local` names |
| `--ref REF` | Follow a branch or tag instead of `main` (see [Updates](Updates.md)) |
| `--dir PATH` | Install somewhere other than `/opt/hbox` |
| `--migrate` | Adopt an existing hbox-apps server ([guide](Migrating-from-hbox-apps.md)) |
| `--yes` | Don't ask for confirmation |
| `--skip-setup` | Install prerequisites and files only; run `sudo hbox setup` later |

## From a local copy

```sh
git clone https://github.com/ishrakr/hbox.git
sudo ./hbox/install.sh
```

The installer copies the program files (never secrets) to `/opt/hbox` and
links it to git, so `hbox update` works as usual.

## After installing

Continue with [First steps](First-steps.md). The login is shown again with
`sudo hbox credentials`.

## Uninstall

```sh
sudo hbox uninstall
```

This stops HBOX and removes its services and the `hbox` command. Data
(`/DATA`), configuration (`/opt/hbox`, `/etc/hbox`) and backups are kept;
running the installer again brings everything back.
