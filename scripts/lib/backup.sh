# shellcheck shell=bash
# Restic backups for HBOX. Sourced by the hbox CLI after common.sh.
#
# A snapshot contains, in one consistent set:
#   - logical dumps of both PostgreSQL databases (taken while running)
#   - Immich uploads, Nextcloud config and data, Dockge and Tailscale state
#   - the HBOX configuration (.env, certificates, local CA)
# Raw PostgreSQL data directories are excluded: copying a live database is not
# a valid backup. Restores rebuild the databases from the dumps instead.

HBOX_BACKUP_ENV=${HBOX_BACKUP_ENV:-$HBOX_ETC/backup.env}
HBOX_RESTIC_PASSWORD_FILE=${HBOX_RESTIC_PASSWORD_FILE:-$HBOX_ETC/restic-password}
HBOX_BACKUP_STATUS=$HBOX_STATE/backup-status
HBOX_RESTIC_CACHE=${HBOX_RESTIC_CACHE:-/var/cache/hbox/restic}

backup_configured() {
    [ -f "$HBOX_BACKUP_ENV" ] && [ -f "$HBOX_RESTIC_PASSWORD_FILE" ] &&
        [ -n "$(env_get RESTIC_REPOSITORY "$HBOX_BACKUP_ENV" 2>/dev/null)" ]
}

require_backup() {
    command -v restic >/dev/null 2>&1 || die "restic is not installed. Re-run the HBOX installer."
    backup_configured || die "Backups are not configured yet. Run: sudo hbox backup setup"
}

# Run restic with the repository, password and backend credentials from
# backup.env, without exporting them to the rest of the CLI.
run_restic() {
    (
        set -a
        # shellcheck disable=SC1090
        . "$HBOX_BACKUP_ENV"
        set +a
        export RESTIC_PASSWORD_FILE=$HBOX_RESTIC_PASSWORD_FILE
        unset RESTIC_PASSWORD RESTIC_PASSWORD_COMMAND
        export RESTIC_CACHE_DIR=$HBOX_RESTIC_CACHE
        exec restic "$@"
    )
}

backup_staging_dir() {
    printf '%s/.hbox-backup' "$(env_get_default DATA_ROOT /DATA)"
}

# Everything a snapshot should contain, if present on this server.
backup_paths() {
    local data
    data=$(env_get_default DATA_ROOT /DATA)
    local candidates=(
        "$HBOX_ENV_FILE"
        "$HBOX_HOME/certs"
        "$HBOX_ETC"
        "$(backup_staging_dir)"
        "$data/immich/upload"
        "$data/nextcloud/config"
        "$data/nextcloud/data"
        "$data/dockge"
        "$data/tailscale"
        "$data/apps"
        "$HBOX_HOME/local"
    )
    local path
    # The database dumps are written just before each snapshot; the folder
    # must be in the list even before the first dump exists.
    install -d -m 700 "$(backup_staging_dir)"
    for path in "${candidates[@]}"; do
        [ -e "$path" ] && printf '%s\n' "$path"
    done
    return 0
}

backup_excludes() {
    local data
    data=$(env_get_default DATA_ROOT /DATA)
    # Regenerable caches; the restic password must never sit inside its own repo.
    printf '%s\n' \
        "$HBOX_RESTIC_PASSWORD_FILE" \
        "$data/nextcloud/data/appdata_*/preview" \
        "$data/immich/upload/thumbs" \
        "$data/immich/upload/encoded-video"
}

backup_write_status() {
    local result=$1 detail=$2
    mkdir -p "$HBOX_STATE"
    {
        printf 'result=%s\n' "$result"
        printf 'time=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'detail=%s\n' "$detail"
    } > "$HBOX_BACKUP_STATUS"
    if declare -F cmd_status_update >/dev/null; then
        cmd_status_update 2>/dev/null || true
    fi
}

backup_notify() {
    local result=$1 url
    url=$(env_get_default HBOX_BACKUP_NOTIFY_URL '' "$HBOX_BACKUP_ENV")
    [ -n "$url" ] || return 0
    # Healthchecks.io-compatible: success pings the URL, failure pings /fail.
    if [ "$result" = success ]; then
        curl -fsS -m 15 --retry 3 "$url" >/dev/null 2>&1 || warn "Backup notification failed."
    else
        curl -fsS -m 15 --retry 3 "${url%/}/fail" >/dev/null 2>&1 || warn "Backup notification failed."
    fi
}

dump_database() {
    local container=$1 user=$2 out=$3
    container_running "$container" ||
        die "$container is not running, so its database cannot be dumped. Start HBOX (sudo hbox start) and retry."
    log "Dumping the $container database"
    # pg_dumpall includes roles and the full schema; --clean makes it restorable
    # over an existing database (Immich's documented backup method).
    if ! docker exec "$container" pg_dumpall --clean --if-exists --username="$user" > "$out.partial"; then
        rm -f "$out.partial"
        die "Database dump from $container failed."
    fi
    [ -s "$out.partial" ] || die "Database dump from $container is empty."
    mv -f "$out.partial" "$out"
}

nextcloud_maintenance() {
    nextcloud_installed || return 0
    occ maintenance:mode "--$1" >/dev/null
}

backup_lock() {
    exec 9>/run/hbox-backup.lock
    flock -n 9 || die "Another backup, check or restore is already running."
    # A restic lock left by a crashed or killed run would block this one. While
    # Backrest runs, it may hold a live lock, and unlocks stale ones itself.
    if ! systemctl is-active --quiet hbox-backrest.service 2>/dev/null; then
        run_restic unlock >/dev/null 2>&1 || true
    fi
}

# A backup disk set up by `hbox backup disk` must be mounted (it is mounted
# again here after being unplugged and plugged back in).
backup_disk_ready() {
    local mount
    mount=$(env_get_default HBOX_BACKUP_MOUNT '' "$HBOX_BACKUP_ENV")
    [ -n "$mount" ] || return 0
    mountpoint -q "$mount" && return 0
    mount "$mount" >/dev/null 2>&1 && mountpoint -q "$mount"
}

# Everything a snapshot needs besides the files: database dumps and a
# manifest. Runs before each snapshot (Backrest's start hook).
backup_prepare() {
    local staging previous_trap
    previous_trap=$(trap -p EXIT)
    require_backup
    require_docker
    backup_disk_ready || {
        backup_write_status failed "the backup disk is not connected"
        die "The backup disk is not connected. Plug it in; backups resume automatically."
    }
    staging=$(backup_staging_dir)
    install -d -m 700 "$staging"
    rm -f "$staging"/*.sql "$staging"/*.partial
    backup_write_status running "started"
    # Leave Nextcloud usable and record the failure if a dump fails.
    trap 'nextcloud_maintenance off 2>/dev/null || true; backup_finish failed' EXIT

    dump_database immich-postgres immich "$staging/immich.sql"
    # Nextcloud is paused only while its database is dumped, keeping the
    # dump consistent without a long outage during the file backup.
    if container_running nextcloud && nextcloud_installed; then
        nextcloud_maintenance on
        dump_database nextcloud-db nextcloud "$staging/nextcloud.sql"
        nextcloud_maintenance off
    else
        dump_database nextcloud-db nextcloud "$staging/nextcloud.sql"
    fi
    {
        printf 'hbox_home=%s\n' "$HBOX_HOME"
        printf 'data_root=%s\n' "$(env_get_default DATA_ROOT /DATA)"
        printf 'immich_version=%s\n' "$(env_get_default IMMICH_VERSION v3.4.1)"
        printf 'nextcloud_image=%s\n' "$(docker inspect -f '{{.Config.Image}}' nextcloud 2>/dev/null || true)"
        printf 'created=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$staging/manifest"
    if [ -n "$previous_trap" ]; then eval "$previous_trap"; else trap - EXIT; fi
}

# After a snapshot: record the result for the dashboard and doctor.
backup_finish() {
    local result=$1
    rm -f "$(backup_staging_dir)"/*.sql "$(backup_staging_dir)"/*.partial
    case $result in
        success) backup_write_status success "snapshot created" ;;
        warning) backup_write_status warning "snapshot created, but some files could not be read" ;;
        *)
            if [ "$(env_get detail "$HBOX_BACKUP_STATUS" 2>/dev/null)" = "the backup disk is not connected" ]; then
                return 0
            fi
            backup_write_status failed "see Backups (https://<server>:6443) for details" ;;
    esac
}

# Backrest's hooks: `hbox backup hook start|success|warning|failed`.
backup_hook() {
    require_root
    case ${1:-} in
        start) backup_lock; backup_prepare ;;
        success | warning | failed) backup_finish "$1" ;;
        *) die "Usage: hbox backup hook start|success|warning|failed" ;;
    esac
}

# Back up now: through Backrest (history, notifications and its retention
# policy apply), or with restic directly if Backrest is not running.
backup_run() {
    require_backup
    if backrest_enabled && backrest_answers; then
        backrest_backup_now
    else
        backup_run_direct
    fi
}

backup_run_direct() {
    local status=0 paths=() excludes=() path instance=hbox
    require_docker
    backup_lock
    # Failures past this point must be recorded and reported, not only printed.
    trap 'backup_finish failed; backup_notify failure' EXIT
    backup_prepare

    mapfile -t paths < <(backup_paths)
    while IFS= read -r path; do
        excludes+=(--exclude "$path")
    done < <(backup_excludes)
    if [ -s "$HBOX_BACKREST_CONFIG" ]; then
        instance=$(jq -r '.instance // "hbox"' "$HBOX_BACKREST_CONFIG")
    fi

    log "Backing up ${#paths[@]} locations to $(env_get RESTIC_REPOSITORY "$HBOX_BACKUP_ENV")"
    # Backrest's tags, so its history and retention include this snapshot.
    run_restic backup --tag hbox --tag "plan:hbox" --tag "created-by:$instance" \
        --host "$(hostname -s)" --one-file-system \
        "${excludes[@]}" "${paths[@]}" || status=$?
    # Exit code 3 means some files could not be read; the snapshot exists.
    if [ "$status" -ne 0 ] && [ "$status" -ne 3 ]; then
        die "restic backup failed (exit code $status)."
    fi

    log "Applying the retention policy"
    run_restic forget --tag hbox --host "$(hostname -s)" --prune \
        --keep-daily "$(env_get_default KEEP_DAILY 7 "$HBOX_BACKUP_ENV")" \
        --keep-weekly "$(env_get_default KEEP_WEEKLY 4 "$HBOX_BACKUP_ENV")" \
        --keep-monthly "$(env_get_default KEEP_MONTHLY 12 "$HBOX_BACKUP_ENV")" \
        --keep-yearly "$(env_get_default KEEP_YEARLY 2 "$HBOX_BACKUP_ENV")" >/dev/null ||
        die "restic forget/prune failed."

    trap - EXIT
    if [ "$status" -eq 3 ]; then
        backup_finish warning
        warn "Backup completed, but some files could not be read (see the output above)."
    else
        backup_finish success
        log "Backup completed."
    fi
    backup_notify success
}

backup_check() {
    require_backup
    local subset
    subset=$(env_get_default CHECK_READ_DATA_SUBSET 5% "$HBOX_BACKUP_ENV")
    backup_lock
    log "Verifying repository structure and $subset of the backed-up data"
    run_restic check --read-data-subset="$subset"
}

backup_setup() {
    local repo='' password_file='' existing=0 creds=() arg
    while [ "$#" -gt 0 ]; do
        case $1 in
            --repo) repo=$2; shift 2 ;;
            --repo=*) repo=${1#*=}; shift ;;
            --password-file) password_file=$2; shift 2 ;;
            --password-file=*) password_file=${1#*=}; shift ;;
            --existing) existing=1; shift ;;
            --env) creds+=("$2"); shift 2 ;;
            --env=*) creds+=("${1#*=}"); shift ;;
            *) die "Unknown option for backup setup: $1" ;;
        esac
    done
    command -v restic >/dev/null 2>&1 || die "restic is not installed. Re-run the HBOX installer."

    if [ -z "$repo" ]; then
        [ -t 0 ] || die "Specify the repository with --repo, or set up a disk with: sudo hbox backup disk"
        cat >&2 <<'EOF'
Where should HBOX store backups? For a USB or second disk, press Ctrl-C and
run `sudo hbox backup disk` instead: it prepares and mounts the disk for you.
Other examples:
  sftp:user@nas.local:/backups/hbox
  s3:s3.amazonaws.com/bucket/hbox   (needs AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY)
  b2:bucket:hbox                    (needs B2_ACCOUNT_ID / B2_ACCOUNT_KEY)
  rest:https://user:pass@host:8000/hbox
EOF
        read -r -p "Repository: " repo
    fi
    [ -n "$repo" ] || die "A repository is required."

    local data
    data=$(env_get_default DATA_ROOT /DATA)
    case $repo in
        /*)
            case "$(readlink -m "$repo")/" in
                "$(readlink -m "$data")"/*) die "The backup repository must not be inside $data: it would back up into itself." ;;
            esac
            if [ "$(stat -c %d "$(dirname "$(readlink -m "$repo")")" 2>/dev/null)" = "$(stat -c %d "$data" 2>/dev/null)" ]; then
                warn "The repository is on the same disk as your data. It will not survive a disk failure; prefer a separate disk, a NAS, or cloud storage."
            fi
            ;;
    esac

    install -d -m 700 "$HBOX_ETC"
    local tmp_env
    tmp_env=$(mktemp "$HBOX_ETC/backup.env.XXXXXX")
    if [ -f "$HBOX_BACKUP_ENV" ]; then
        # Keep tuning and credentials across re-runs unless replaced below.
        grep -v '^RESTIC_REPOSITORY=' "$HBOX_BACKUP_ENV" > "$tmp_env" || true
    else
        cat > "$tmp_env" <<'EOF'
# HBOX restic backup settings. Keep this file private (mode 600).
# Retention: how many daily/weekly/monthly/yearly snapshots to keep.
KEEP_DAILY=7
KEEP_WEEKLY=4
KEEP_MONTHLY=12
KEEP_YEARLY=2
# Weekly integrity check reads this share of the stored data.
CHECK_READ_DATA_SUBSET=5%
# Optional Healthchecks.io-style URL: pinged on success, <url>/fail on failure.
HBOX_BACKUP_NOTIFY_URL=
EOF
    fi
    env_set RESTIC_REPOSITORY "$repo" "$tmp_env"
    # The backup disk's mount point, set by `hbox backup disk`.
    if [ -n "${HBOX_BACKUP_MOUNT_SET:-}" ]; then
        env_set HBOX_BACKUP_MOUNT "$HBOX_BACKUP_MOUNT_SET" "$tmp_env"
    else
        sed -i '/^HBOX_BACKUP_MOUNT=/d' "$tmp_env"
    fi
    for arg in "${creds[@]}"; do
        [[ $arg == *=* ]] || die "--env expects KEY=VALUE, got: $arg"
        [[ ${arg%%=*} =~ ^[A-Z][A-Z0-9_]*$ ]] || die "Invalid variable name: ${arg%%=*}"
        env_set "${arg%%=*}" "${arg#*=}" "$tmp_env"
    done

    local tmp_password
    tmp_password=$(mktemp "$HBOX_ETC/restic-password.XXXXXX")
    chmod 600 "$tmp_password"
    if [ -n "$password_file" ]; then
        [ -s "$password_file" ] || die "Password file $password_file is empty or missing."
        cat -- "$password_file" > "$tmp_password"
    elif [ -f "$HBOX_RESTIC_PASSWORD_FILE" ]; then
        cat -- "$HBOX_RESTIC_PASSWORD_FILE" > "$tmp_password"
    elif [ "$existing" -eq 1 ]; then
        [ -t 0 ] || die "Provide the existing repository password with --password-file."
        local password
        read -r -s -p "Existing repository password: " password
        echo >&2
        printf '%s\n' "$password" > "$tmp_password"
    else
        openssl rand -base64 32 > "$tmp_password"
    fi

    mv -f "$tmp_env" "$HBOX_BACKUP_ENV"
    mv -f "$tmp_password" "$HBOX_RESTIC_PASSWORD_FILE"
    chmod 600 "$HBOX_BACKUP_ENV" "$HBOX_RESTIC_PASSWORD_FILE"

    if run_restic cat config >/dev/null 2>&1; then
        log "Using the existing restic repository."
    elif [ "$existing" -eq 1 ]; then
        die "Cannot open the repository at $repo with that password."
    else
        case $repo in /*) install -d -m 700 "$repo" ;; esac
        log "Initializing a new encrypted restic repository"
        run_restic init >/dev/null || die "restic could not initialize $repo."
    fi

    systemctl daemon-reload
    # A previous deployment's backup job, kept by migration until now.
    if [ -f "$HBOX_SYSTEMD_DIR/hbox-legacy-backup.timer" ]; then
        systemctl disable --now hbox-legacy-backup.timer >/dev/null 2>&1 || true
        log "Stopped the previous backup job (hbox-legacy-backup.timer); its snapshots stay in the repository."
    fi
    # Snapshots from before Backrest (or from the previous job) join its plan.
    [ "$existing" -eq 1 ] && backrest_adopt_snapshots
    log "Starting Backups (Backrest), which runs and manages the backups"
    backrest_sync
    log "Backups run nightly at 03:00, with a weekly integrity check. Manage them at https://$(primary_ip || echo hbox.local):$HBOX_BACKUPS_PORT/"

    if [ "$existing" -eq 0 ] && [ -z "$password_file" ]; then
        heading "IMPORTANT: save this repository password somewhere safe (not on this server)."
        printf '\n    %s\n\n' "$(cat "$HBOX_RESTIC_PASSWORD_FILE")" >&2
        printf 'Without it, the backups cannot be restored. It is stored in %s.\n' \
            "$HBOX_RESTIC_PASSWORD_FILE" >&2
        printf 'Show it again any time with: sudo hbox backup password\n' >&2
    fi
}

backup_status() {
    if ! backup_configured; then
        echo "Backups: not configured (run: sudo hbox backup setup)"
        return 0
    fi
    echo "Repository: $(env_get RESTIC_REPOSITORY "$HBOX_BACKUP_ENV")"
    if [ -f "$HBOX_BACKUP_STATUS" ]; then
        echo "Last run:   $(env_get time "$HBOX_BACKUP_STATUS") ($(env_get result "$HBOX_BACKUP_STATUS"): $(env_get detail "$HBOX_BACKUP_STATUS"))"
    else
        echo "Last run:   never"
    fi
    local mount summary
    mount=$(env_get_default HBOX_BACKUP_MOUNT '' "$HBOX_BACKUP_ENV")
    if [ -n "$mount" ]; then
        if mountpoint -q "$mount"; then
            echo "Disk:       connected ($(df -h --output=avail "$mount" | tail -n 1 | tr -d ' ') free)"
        else
            echo "Disk:       NOT CONNECTED (plug in the backup disk)"
        fi
    fi
    if summary=$(backrest_summary 2>/dev/null); then
        echo "Snapshots:  $(jq -r .snapshots <<<"$summary")"
        echo "Next run:   $(jq -r '.next | if . == "" then "not scheduled" else (fromdate | localtime | strftime("%a %Y-%m-%d %H:%M")) end' <<<"$summary")"
    fi
    echo "Manage:     https://$(primary_ip || echo hbox.local):$HBOX_BACKUPS_PORT/  (Backups)"
}

restore_database() {
    local stack=$1 container=$2 user=$3 dump=$4 mode=$6 dir backup_dir ts
    dir=$(env_get_default DATA_ROOT /DATA)/$5
    ts=$(date +%Y%m%d-%H%M%S)
    [ -s "$dump" ] || die "The snapshot does not contain $(basename "$dump")."

    # Never delete the current database: set it aside for manual recovery.
    if [ -d "$dir" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then
        backup_dir="$dir.pre-restore-$ts"
        log "Keeping the previous $container data at $backup_dir"
        mv -- "$dir" "$backup_dir"
    fi
    # Same modes as hbox setup: PostgreSQL 18 mounts the parent of PGDATA.
    install -d -m "$mode" "$dir"

    stack_compose "$stack" up -d "$container"
    wait_until 180 "$container" container_healthy "$container"
    log "Loading the $container database dump"
    # Same transformation as Immich's documented restore procedure.
    sed "s/SELECT pg_catalog.set_config('search_path', '', false);/SELECT pg_catalog.set_config('search_path', 'public, pg_catalog', true);/g" "$dump" |
        docker exec -i "$container" psql --quiet --dbname=postgres --username="$user" >/dev/null 2>"$HBOX_STATE/restore-$container.log" || true
    local tables
    tables=$(docker exec "$container" psql -tA --username="$user" --dbname="$user" \
        -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")
    [ "${tables:-0}" -gt 0 ] ||
        die "The $container database is empty after restore. See $HBOX_STATE/restore-$container.log"
    log "Restored $container ($tables tables)."
}

backup_restore() {
    local snapshot=latest
    while [ "$#" -gt 0 ]; do
        case $1 in
            --yes | -y) export HBOX_ASSUME_YES=1; shift ;;
            -*) die "Unknown option for restore: $1" ;;
            *) snapshot=$1; shift ;;
        esac
    done
    require_backup
    require_docker

    run_restic snapshots --tag hbox "$snapshot" >/dev/null 2>&1 ||
        die "Snapshot '$snapshot' was not found. List snapshots with: sudo hbox backup snapshots"
    heading "Restore HBOX from snapshot '$snapshot'"
    cat >&2 <<EOF
This replaces the HBOX configuration, photos, files and both databases on this
server with the contents of the snapshot. Anything added since that snapshot is
lost. Current database directories are kept as *.pre-restore-<time> folders.
EOF
    confirm "Continue with the restore?" || die "Restore cancelled."
    backup_disk_ready || die "The backup disk is not connected."
    # No scheduled backup may start while files are being replaced.
    systemctl stop hbox-backrest.service >/dev/null 2>&1 || true
    backup_lock

    log "Stopping HBOX"
    local stack
    for stack in hbox-tailscale hbox-files hbox-photos hbox-core; do
        stack_compose "$stack" down >/dev/null 2>&1 || true
    done
    stack_compose hbox-dockge stop >/dev/null 2>&1 || true

    log "Restoring files (this can take a long time for large libraries)"
    # Keep this server's repository settings and password; restore the rest.
    run_restic restore "$snapshot" --tag hbox --target / \
        --exclude "$HBOX_BACKUP_ENV" --exclude "$HBOX_RESTIC_PASSWORD_FILE" ||
        die "restic restore failed."

    local staging
    staging=$(backup_staging_dir)
    ensure_network
    restore_database hbox-photos immich-postgres immich "$staging/immich.sql" immich/pgdata 700
    restore_database hbox-files nextcloud-db nextcloud "$staging/nextcloud.sql" nextcloud/pgdata 755
    rm -f "$staging"/*.sql

    log "Starting HBOX"
    hbox_start_all
    if wait_for_nextcloud 300; then
        occ maintenance:mode --off >/dev/null 2>&1 || true
        # Tell sync clients the data changed so they re-check instead of deleting.
        occ maintenance:data-fingerprint >/dev/null 2>&1 || true
    else
        warn "Nextcloud did not become ready; check it with: sudo hbox logs nextcloud"
    fi
    # The restored Backrest settings are brought in line with this server.
    (backrest_sync) || warn "Backups (Backrest) did not start; run: sudo hbox backup backrest-sync"
    log "Restore complete."
}
