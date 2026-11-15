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
- includes `/DATA/apps/<name>` in backups (and its database, if it declares one).

## Shipped apps

| App | Port | Software |
| --- | --- | --- |
| `paperless` | 7443 | [Paperless-ngx](https://docs.paperless-ngx.com): scan, OCR, search and file paperwork ("Documents") |
| `status` | 4443 | [Uptime Kuma](https://github.com/louislam/uptime-kuma): uptime monitoring and alerts |

## Documents (Paperless-ngx)

```sh
sudo hbox apps enable paperless     # https://<server>:7443
```

- **Sign in** with the HBOX administrator login (`sudo hbox credentials`).
  Add accounts for others in Documents: Settings > Users & Groups.
- **Adding documents:** upload in the browser, use the Paperless mobile apps
  (server `https://<server>:7443`), or drop files into
  `/DATA/apps/paperless/consume` (for example from a scanner's network
  folder). Subfolders become tags.
- **Text recognition** uses English. Set another language in
  `/opt/hbox/.env` and run `sudo hbox update`:

  ```sh
  PAPERLESS_OCR_LANGUAGE=deu+eng     # languages documents are read in
  PAPERLESS_OCR_LANGUAGES=ben        # extra ones to install (beyond eng deu fra ita spa)
  ```

- **Backups** include the documents (`media`), the search index and settings
  (`data`) and a dump of its database, taken before each backup. A restore
  brings all of it back.
- **Version:** `PAPERLESS_VERSION` in `.env` holds it at a version of your
  choice.

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
| `secrets` | `.env` keys generated once when the app is enabled, e.g. `["NOTES_SECRET_KEY"]` (optional) |
| `database` | A PostgreSQL service: `{"service", "container", "user", "dir"}`. It is dumped before each backup and loaded on restore; its folder `dir` under the app's data is left out of the file backup (optional) |
| `exclude` | Folders under the app's data not worth backing up, such as caches (optional) |

An optional `setup.sh` next to them runs after every start (enable, update,
restore, weekly maintenance), with `HBOX_APP` and `HBOX_APP_DATA` set and
HBOX's helpers available. Make it safe to run again.

Then `sudo hbox apps enable notes`.
