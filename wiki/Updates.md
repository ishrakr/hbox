# Updates

`/opt/hbox` is a git checkout of [ishrakr/hbox](https://github.com/ishrakr/hbox).
Everything HBOX runs comes from it: app versions, the nginx configuration, the
dashboard, the `hbox` command, system services, optional apps and
[patches](Patches.md). Servers pick up changes with:

```sh
sudo hbox update            # back up, then install the latest version
sudo hbox update --check    # is there a newer version, and what changed?
sudo hbox rollback          # back to the version before the last update
sudo hbox version
```

Or from the [dashboard](Dashboard.md#update-button): **Check for updates**,
then **Update now**.

## What an update does

1. Stops if files tracked by git were edited on the server (see
   [Local changes](#local-changes)).
2. Backs up, unless `--skip-backup`.
3. Fetches and checks out the new version. A branch must move forward;
   going back is `hbox rollback`.
4. Continues with the **new** `hbox` command: runs new patches once, pulls
   changed images, recreates changed containers, reloads nginx and
   reinstalls the system services.

Nothing is built on the server: apps run upstream images, and the nginx
configuration and dashboard are mounted from the checkout.

## Release channels

Set `HBOX_REF` in `/opt/hbox/.env`, or once with `sudo hbox update --ref ...`:

| `HBOX_REF` | Server gets |
| --- | --- |
| `main` (default) | Every commit pushed to `main` |
| `stable` | The newest release tag (`vX.Y.Z`) |
| `v1.2.0` | Exactly that release, until changed |
| a branch | e.g. `testing` for one server |

## Automatic updates

A daily timer (04:30) checks for updates and shows "update available" on the
dashboard. With `HBOX_AUTO_UPDATE=1` in `.env`, it also installs them (backup
first).

## Rollback

```sh
sudo hbox rollback           # the version before the last update
sudo hbox rollback v1.2.0    # a specific version
```

Rollback restores HBOX's files and app versions and restarts what changed. It
doesn't touch data. If an update already let an app upgrade its database, an
older app version may refuse to start: then restore the backup the update made
([Restore](Restore.md#everything)).

## Local changes

Keep server-only changes where updates don't touch them:

| Change | Where |
| --- | --- |
| Settings, app version pins | `/opt/hbox/.env` |
| Your own apps | `/opt/hbox/local/apps/<name>/` |
| Your own dashboard links | `/opt/hbox/local/dashboard.json` |

Editing tracked files directly makes the next update stop with the list of
changed files. Undo them (`sudo git -C /opt/hbox checkout -- <file>`), or
commit the change to the repository so every server gets it.
