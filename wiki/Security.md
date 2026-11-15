# Security

HBOX is built for a home network and Tailscale, not the public internet.

## Don't expose HBOX to the internet

Never forward ports 80, 443, 2443, 3443, 5443, 6443 (or optional apps' ports)
on your router. Admin and Backups control the whole server. For access away
from home, use [Remote access](Remote-access.md): only devices on your
tailnet can connect.

## What protects what

| | Protection |
| --- | --- |
| All web traffic | HTTPS with HBOX's own CA; apps' direct ports listen on localhost only |
| Photos, Files | Their own accounts |
| Admin (Dockge) | Administrator login; anyone with it controls the server (Docker is root access) |
| Backups (Backrest) | Administrator login; Backrest listens only on Docker's internal bridge |
| Dashboard update button | Administrator login, rate-limited; nginx can only drop a request file |
| Backups | Encrypted with the repository password, which is never stored in the backup itself |
| Secrets | `/etc/hbox` and `.env` are readable by root only |

## Passwords

- The administrator password is generated at install: `sudo hbox credentials`.
  It is used by Files, Photos (by e-mail), Admin, Backups and the update button.
- Change it in each app's own settings. For Backups and the update button,
  edit `ADMIN_PASSWORD` in `/etc/hbox/credentials` and run `sudo hbox update`.
- Database passwords are random and never needed by hand.
- Keep the backup repository password off the server: it is the only key to
  your backups.

## Updates

Security fixes arrive with HBOX updates (checked daily, shown on the
dashboard). Turn on `HBOX_AUTO_UPDATE=1` to install them automatically.
Keep the operating system updated too, e.g. with `unattended-upgrades`.
