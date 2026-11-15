# Development

## Repository

```text
install.sh             Installer (Ubuntu/Debian)
scripts/hbox           The hbox command
scripts/lib/           Its parts: common, backup, backrest, disk, apps, update, dashboard
scripts/hbox-mdns      .local name announcements
scripts/generate-certs.sh   CA and server certificate
stacks/hbox-*/         Compose stacks: core (nginx), photos, files, tailscale
manager/               Admin (Dockge) stack
config/nginx/          nginx site, mounted into the stock image
config/dashboard/      Dashboard (static HTML/CSS/JS, app logos)
apps/                  Optional apps
migrations/            One-time patches (see Patches)
systemd/               Services and timers
tests/                 Unit and live-nginx tests
wiki/                  This documentation
```

There is no build step: servers run upstream images and take HBOX's files from
git.

## Checks

```sh
make check     # tests (Python 3, standard library)
make config    # validate every compose file (Docker)
make lint      # shellcheck all scripts (Docker)
```

`make check` also runs live proxy tests against a real nginx when `nginx` is
on `PATH` or `NGINX_BINARY` points at one (it needs the `http_dav` module);
otherwise they are skipped. GitHub Actions runs all three on every push and
pull request.

## Testing on a VM

Any VM with systemd works, e.g. with [OrbStack](https://orbstack.dev) or
Multipass. Install from your working copy:

```sh
sudo ./install.sh --yes
```

To test updates without pushing, serve the repository from a local bare
clone:

```sh
git clone --bare . /tmp/hbox-origin.git
# on the VM:
HBOX_REPO=/tmp/hbox-origin.git sudo -E ./install.sh --yes
# after committing a change:
git push /tmp/hbox-origin.git main --tags
sudo hbox update      # on the VM
```

To test a backup disk without hardware, use a loop device:

```sh
truncate -s 20G /root/disk.img && sudo losetup -fP --show /root/disk.img
sudo HBOX_BACKUP_ALLOW_LOOP=1 hbox backup disk /dev/loop0
```

## Releasing

```sh
git push                         # servers on main get it
git tag v1.3.0 && git push --tags     # servers on stable get it
```

Before tagging, add the release to `CHANGELOG.md`.

Typical changes:

| Change | How |
| --- | --- |
| New app version | Change the image tag in `stacks/*/compose.yaml`; read the release notes first. Nextcloud moves one major version per release. |
| Fix or new setting | Edit the file; it reaches servers on update |
| Something that must happen once on existing servers | Add a [patch](Patches.md) |
| New optional software | Add `apps/<name>/` ([Optional apps](Optional-apps.md)) |

Keep `main` releasable: servers following it install every push.

## Wiki

The wiki lives in `wiki/`. Edit it with the code it describes, then publish
it to the GitHub wiki with `make wiki`.
