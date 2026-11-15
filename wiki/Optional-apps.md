# Optional apps

```sh
sudo hbox apps list
sudo hbox apps enable status      # Uptime Kuma at https://<server>:4443
sudo hbox apps disable status     # stops it; data stays in /DATA/apps/status
```

Enabling an app:

- runs it as Compose project `hbox-app-<name>` (also listed in Admin);
- serves it over HTTPS on its own port on every address of the server;
- adds it to the dashboard with its logo and a health check;
- includes `/DATA/apps/<name>` in backups.

## Shipped apps

| App | Port | Software |
| --- | --- | --- |
| `status` | 4443 | [Uptime Kuma](https://github.com/louislam/uptime-kuma): uptime monitoring and alerts |

## Adding an app

An app is a folder: `apps/<name>/` in the repository (reaches every server
with `hbox update`; each server still enables it) or
`/opt/hbox/local/apps/<name>/` (this server only, never touched by updates).

```text
apps/notes/
  compose.yaml   the containers
  app.json       how HBOX serves it
  logo.svg       optional dashboard logo (or logo.png)
```

`compose.yaml`:

```yaml
services:
  notes:
    image: example/notes:1.2.3          # pin a version, never :latest
    container_name: hbox-notes          # unique; nginx reaches it by this name
    volumes:
      - ${DATA_ROOT:-/DATA}/apps/notes:/data   # HBOX creates this folder
    environment:
      TZ: ${TZ:-Etc/UTC}
    networks: [frontend]
    restart: unless-stopped
networks:
  frontend:
    name: hbox-frontend
    external: true
```

Don't publish ports: nginx reaches the container on the `hbox-frontend`
network. Settings from `/opt/hbox/.env` (`DATA_ROOT`, `TZ`, ...) are available.

`app.json`:

```json
{
  "name": "Notes",
  "description": "Shared notes",
  "port": 4444,
  "upstream": "http://hbox-notes:8080",
  "health": "/",
  "max_body": "100M"
}
```

| Field | Meaning |
| --- | --- |
| `name`, `description` | Dashboard card |
| `port` | HTTPS port, 1024–65535; 80, 443, 2443, 3443, 5443 and 6443 belong to HBOX |
| `upstream` | `http://container:port` on `hbox-frontend` |
| `health` | Path that answers when the app is up (optional) |
| `max_body` | Upload limit (optional, default `100M`) |

Then `sudo hbox apps enable notes`.
