# Patches

Most changes reach servers just by changing files in git. A **patch** is for
what a file change can't do on its own, once per existing server: change a
setting stored in an app's database, remove an old Docker network, rename a
folder, and so on.

Patches are `migrations/NNNN-description.sh`. `hbox update` runs the new ones
in order, after checking out the new version and before restarting apps.

## Rules

- Name: four digits, a dash, a description: `0001-rename-x.sh`. Never
  renumber or change a released patch; add a new one.
- They are sourced by `hbox` with `set -Eeuo pipefail`, so its helpers are
  available: `log`, `warn`, `die`, `env_get`, `env_set`, `occ`,
  `stack_compose`, `container_running`, `wait_for_nextcloud`, ...
- Make them safe to run twice: if one fails, the update stops and the same
  patch runs again next time.
- A fresh install marks all existing patches as done, so write them for
  servers installed before the patch.

Done patches are listed in `/var/lib/hbox/migrations.done`.

## Example

```sh
# shellcheck shell=bash
# Nextcloud: allow larger chunked uploads on existing servers.
if container_running nextcloud && nextcloud_installed; then
    log "  Raising Nextcloud's upload chunk size"
    occ config:app:set files max_chunk_size --value 104857600 >/dev/null
fi
```
