# Dashboard

`https://hbox.local` (or any address of the server) shows:

- **Apps** with their logos and whether each one responds;
- **Storage**: space used and free on the data disk;
- **Backups**: last backup, next run, number of backups, size protected, and
  whether the backup disk is connected;
- **Software**: the HBOX version, **Check for updates** and, when one is
  available, **Update now**.

Status is refreshed every minute by the host (`hbox-status.timer`).

## Update button

**Update now** asks for the HBOX administrator login (`sudo hbox credentials`)
and then runs the same update as `sudo hbox update`, backup first. Progress is
shown on the page, and it reloads when done. The output of the last run is in
`/var/lib/hbox/update.log`.

How it works: nginx can only drop a request file into `/var/lib/hbox/requests`.
`hbox-dashboard.path` notices it and runs `hbox dashboard-actions` as root,
which reports progress in `/var/lib/hbox/dashboard/update.json`. Login
attempts are rate-limited, and requests need a custom header, so other web
pages cannot trigger them.

## Your own links

The app list is `config/dashboard/apps.json`. For a link only on one server,
copy it to `/opt/hbox/local/dashboard.json`, edit it, and run
`sudo hbox update`:

```json
{ "name": "Router", "description": "Home network", "href": "http://192.168.1.1" }
```

| Field | Meaning |
| --- | --- |
| `name`, `description` | Card text |
| `port` | An HTTPS port on this server; the link uses whichever address the dashboard was opened with |
| `href` | Any other link (instead of `port`) |
| `logo` | An SVG or PNG file name in `config/dashboard/icons/` |
| `health` | Name of a `/health/<name>` check (shipped apps only) |

[Optional apps](Optional-apps.md) add their own card automatically.
