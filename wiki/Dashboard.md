# Dashboard

`https://hbox.local` (or any address of the server) shows:

- **Apps** with their logos and whether each one responds;
- **Server**, one status line:
  - **CPU** and **Memory** in use (memory not counting caches the system
    frees on demand);
  - **Network**: download and upload speed of the server's network ports
    (not traffic between the apps inside it);
  - **Storage**: space free on the data disk;
  - **Disks**: the health of the server and backup drives as they report it
    themselves (SMART).

  Values turn orange or red when they need attention, and a disk with
  problems adds a message below the line saying what to do. Hover over (or
  tap) a value for details: the hour's average and peak CPU, memory and swap
  in use, data transferred in the last hour, each drive's model and
  temperature.
- **Backups**: last backup, next run, number of backups, size protected, and
  whether the backup disk is connected;
- **Software**: the HBOX version, **Check for updates** and, when one is
  available, **Update now**.

Status is refreshed every minute by the host (`hbox-status.timer`). CPU and
network values are averages over that minute; the hour of history is kept in
`/var/lib/hbox/usage.json`. Drive health is read at most hourly
(`/var/lib/hbox/disk-health.json`) and never wakes a sleeping backup disk;
`sudo hbox doctor` reads it fresh. Virtual disks that report no health are not
shown.

## Power menu

The power button at the top right opens:

| Action | What happens |
| --- | --- |
| **Restart apps** | Photos, Files and optional apps stop and start again (a minute or two) |
| **Stop apps** | They stay stopped, also after a restart, until **Start apps**. The dashboard, Admin, Backups and remote access keep running |
| **Restart server** | Reboots; everything is back in a few minutes, and the page reconnects on its own |
| **Shut down server** | Powers off. It cannot be started from the dashboard: press the server's power button |

Each asks for the HBOX administrator login, as the update button does. HBOX
first waits (up to 30 minutes) for a running backup, update or restore to
finish, so none is cut off. Progress is shown at the top of the page;
`/var/lib/hbox/power.log` has the details of the last app action.

Over Tailscale, a restart drops your connection until the server is back, and
after a shutdown the server stays off until someone presses its power button.

## Update button

**Update now** asks for the HBOX administrator login (`sudo hbox credentials`)
and then runs the same update as `sudo hbox update`, backup first. Progress is
shown on the page, and it reloads when done. The output of the last run is in
`/var/lib/hbox/update.log`.

How it works: nginx can only drop a request file into `/var/lib/hbox/requests`.
`hbox-dashboard.path` notices it and runs `hbox dashboard-actions` as root,
which reports progress in `/var/lib/hbox/dashboard/update.json` (power
actions: `power.json`). Login
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
