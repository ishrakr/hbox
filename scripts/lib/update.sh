# shellcheck shell=bash
# Updates from git, one-time patches (migrations/) and rollback. Sourced by the
# hbox CLI after common.sh.
#
# /opt/hbox is a git checkout of HBOX_REPO. `hbox update`:
#   1. backs up (unless --skip-backup),
#   2. fetches HBOX_REF (a branch such as main, or a tag such as v1.2.0),
#   3. checks the new revision out (fast-forward or tag), remembering the old,
#   4. runs migrations/NNNN-*.sh that have not run on this server yet,
#   5. pulls images, restarts what changed and reloads nginx.
# If a step fails before the apps were changed, the old revision is restored.

HBOX_MIGRATIONS_DONE=$HBOX_STATE/migrations.done
HBOX_UPDATE_STATE=$HBOX_STATE/update-state
HBOX_PREVIOUS_REV=$HBOX_STATE/previous-revision

hbox_is_git() {
    git -C "$HBOX_HOME" rev-parse --git-dir >/dev/null 2>&1
}

hbox_git() {
    # The checkout belongs to root; never let a different owner's config in.
    git -c safe.directory="$HBOX_HOME" -C "$HBOX_HOME" "$@"
}

hbox_revision() {
    hbox_is_git || { echo unknown; return 0; }
    hbox_git describe --tags --always --dirty 2>/dev/null || echo unknown
}

hbox_commit() {
    hbox_git rev-parse HEAD 2>/dev/null
}

# HBOX_REF: a branch (main), a tag (v1.2.0), or "stable" for the newest
# release tag (vX.Y.Z).
update_ref() {
    env_get_default HBOX_REF main
}

# Make /opt/hbox a git checkout if it was installed from a copied directory,
# keeping the files in place (the server's .env, certs and links are ignored).
ensure_git_checkout() {
    hbox_is_git && return 0
    local repo
    repo=$(env_get_default HBOX_REPO https://github.com/ishrakr/hbox.git)
    log "Connecting $HBOX_HOME to $repo for updates"
    hbox_git init -q
    hbox_git remote add origin "$repo"
    local target
    target=$(fetch_target)
    # Adopt the fetched revision's history without touching the working tree;
    # the next update then shows exactly what differs.
    hbox_git reset -q "$target"
    # Files the copy lacked (e.g. empty placeholders) are restored; changed
    # files are left alone and reported by the update.
    hbox_git ls-files --deleted -z | xargs -0 -r git -c safe.directory="$HBOX_HOME" -C "$HBOX_HOME" checkout -q --
}

# Resolve the configured ref on origin to a commit.
fetch_target() {
    local ref
    ref=$(update_ref)
    hbox_git remote set-url origin "$(env_get_default HBOX_REPO "$(hbox_git remote get-url origin)")"
    if [ "$ref" = stable ]; then
        hbox_git fetch -q --tags --force origin 2>/dev/null ||
            die "Could not fetch from $(hbox_git remote get-url origin). Check the network."
        ref=$(hbox_git tag -l 'v[0-9]*' --sort=-v:refname | head -n 1)
        [ -n "$ref" ] || die "The repository has no release tags (vX.Y.Z) yet; set HBOX_REF=main."
        hbox_git rev-parse "$ref^{commit}"
        return
    fi
    if ! hbox_git fetch -q --tags --force origin "$ref" 2>/dev/null; then
        # Reachable but without that ref (an empty repository, a typo)?
        if hbox_git ls-remote origin >/dev/null 2>&1; then
            die "'$ref' does not exist in $(hbox_git remote get-url origin). Set HBOX_REF to an existing branch or tag."
        fi
        die "Could not reach $(hbox_git remote get-url origin). Check the network (or HBOX_REPO)."
    fi
    # A tag fetches as a tag object; updates need the commit it points to.
    hbox_git rev-parse 'FETCH_HEAD^{commit}'
}

# Refuse to throw away changes made directly on the server; they belong in git
# (or in .env, local/ and apps' overrides, which git ignores).
require_clean_checkout() {
    local changes
    changes=$(hbox_git status --porcelain --untracked-files=no)
    [ -z "$changes" ] && return 0
    printf '%s\n' "$changes" >&2
    die "Files tracked by git were changed on this server (above). Keep local changes in .env or local/, then run: sudo git -C $HBOX_HOME stash   (or checkout -- <file>)"
}

# Version of a commit as shown to people: its tag if it has one.
describe_commit() {
    hbox_git describe --tags --always "$1" 2>/dev/null || printf '%s' "${1:0:12}"
}

# ---------------------------------------------------------------- migrations

migration_done() {
    [ -f "$HBOX_MIGRATIONS_DONE" ] && grep -Fxq -- "$1" "$HBOX_MIGRATIONS_DONE"
}

pending_migrations() {
    local file name
    for file in "$HBOX_HOME"/migrations/[0-9][0-9][0-9][0-9]-*.sh; do
        [ -f "$file" ] || continue
        name=$(basename "$file" .sh)
        migration_done "$name" || printf '%s\n' "$file"
    done
}

# Each migration runs once, in order, with the CLI's helpers available
# (log, warn, die, env_get, env_set, occ, stack_compose, ...). A failing
# migration stops the update; it runs again next time.
run_migrations() {
    local file name
    install -d -m 711 "$HBOX_STATE"
    touch "$HBOX_MIGRATIONS_DONE"
    while IFS= read -r file; do
        name=$(basename "$file" .sh)
        log "Applying patch $name"
        if ! (set -Eeuo pipefail; HBOX_MIGRATION=$name; export HBOX_MIGRATION
            # shellcheck disable=SC1090
            . "$file"); then
            die "Patch $name failed. Fix the cause and run: sudo hbox update"
        fi
        printf '%s\n' "$name" >> "$HBOX_MIGRATIONS_DONE"
    done < <(pending_migrations)
}

# A fresh install already has everything the existing migrations add.
mark_migrations_done() {
    local file
    install -d -m 711 "$HBOX_STATE"
    touch "$HBOX_MIGRATIONS_DONE"
    for file in "$HBOX_HOME"/migrations/[0-9][0-9][0-9][0-9]-*.sh; do
        [ -f "$file" ] || continue
        migration_done "$(basename "$file" .sh)" || basename "$file" .sh >> "$HBOX_MIGRATIONS_DONE"
    done
}

# ---------------------------------------------------------------- check

# Record whether a newer revision exists; the dashboard shows it.
update_check() {
    hbox_is_git || return 0
    local current target behind=0 latest
    current=$(hbox_commit)
    target=$(fetch_target) || return 1
    if [ "$current" != "$target" ]; then
        behind=$(hbox_git rev-list --count "$current..$target" 2>/dev/null || echo 1)
    fi
    latest=$(describe_commit "$target")
    {
        printf 'checked=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'current=%s\n' "$(hbox_revision)"
        printf 'latest=%s\n' "$latest"
        printf 'behind=%s\n' "$behind"
    } > "$HBOX_UPDATE_STATE"
    cmd_status_update 2>/dev/null || true
    if [ "$behind" -gt 0 ]; then
        log "Update available: $(hbox_revision) -> $latest ($behind change(s)). Install with: sudo hbox update"
        hbox_git log --oneline --no-decorate "$current..$target" 2>/dev/null | head -n 20 | sed 's/^/    /' >&2
    else
        log "HBOX is up to date ($(hbox_revision), following $(update_ref))."
    fi
}

# Unattended path for hbox-update.timer: check, and install only when
# HBOX_AUTO_UPDATE=1 (backup first, as always).
update_auto() {
    update_check || return 1
    [ "$(env_get_default HBOX_AUTO_UPDATE 0)" = 1 ] || return 0
    [ "$(env_get_default behind 0 "$HBOX_UPDATE_STATE")" -gt 0 ] || return 0
    HBOX_ASSUME_YES=1 cmd_update --yes
}

# ---------------------------------------------------------------- apply

# Check out TARGET; returns the commit that was checked out before.
checkout_target() {
    local target=$1 previous
    previous=$(hbox_commit)
    if [ "$previous" = "$target" ]; then
        printf '%s' "$previous"
        return 0
    fi
    # A tag channel may move backwards (pinning an older release); a branch
    # must fast-forward so that nothing on the server is silently dropped.
    if hbox_git merge-base --is-ancestor "$previous" "$target" 2>/dev/null ||
        [ "$(env_get_default HBOX_ALLOW_DOWNGRADE 0)" = 1 ]; then
        hbox_git checkout -q --detach "$target"
    else
        die "$(update_ref) ($(describe_commit "$target")) does not contain this server's revision ($(describe_commit "$previous")). To move to it anyway: HBOX_ALLOW_DOWNGRADE=1 sudo -E hbox update"
    fi
    printf '%s' "$previous" > "$HBOX_PREVIOUS_REV"
    printf '%s' "$previous"
}

# Everything after the files are in place: shared by update and rollback.
apply_revision() {
    chmod 755 "$HBOX_HOME/scripts/hbox" "$HBOX_HOME/scripts/hbox-mdns" "$HBOX_HOME/scripts/generate-certs.sh"
    link_stack_env
    ensure_network
    ensure_runtime_dirs
    run_migrations
    apps_render_all
    setup_images
    hbox_start_all
    apps_start_enabled
    setup_certs
    nginx_reload
    # New HBOX releases may add names Nextcloud must accept.
    if wait_for_nextcloud 300 && nextcloud_installed; then
        configure_nextcloud_proxy
    fi
    setup_systemd
    docker image prune -f >/dev/null
    # Refresh "up to date" / "update available" (a rollback is behind again).
    rm -f "$HBOX_UPDATE_STATE"
    (update_check) >/dev/null 2>&1 || true
    cmd_status_update 2>/dev/null || true
}

cmd_update() {
    require_root
    require_docker
    require_env
    local skip_backup=0 check_only=0 ref=''
    while [ "$#" -gt 0 ]; do
        case $1 in
            --skip-backup) skip_backup=1; shift ;;
            --check) check_only=1; shift ;;
            --auto) update_auto; return ;;
            --apply-only) cmd_update_apply_only; return ;;
            --ref) ref=$2; shift 2 ;;
            --ref=*) ref=${1#*=}; shift ;;
            --yes | -y) export HBOX_ASSUME_YES=1; shift ;;
            *) die "Unknown option for update: $1 (see: hbox help)" ;;
        esac
    done
    [ -n "$ref" ] && env_set HBOX_REF "$ref"
    exec 8>/run/hbox-update.lock
    flock -n 8 || die "Another update is already running."

    ensure_git_checkout
    if [ "$check_only" = 1 ]; then
        update_check
        return
    fi

    require_clean_checkout
    local target previous
    target=$(fetch_target)
    previous=$(hbox_commit)
    if [ "$target" = "$previous" ] && [ -z "$(pending_migrations)" ]; then
        log "Already at the latest $(update_ref) ($(hbox_revision)); re-applying configuration."
    else
        log "Updating HBOX: $(hbox_revision) -> $(describe_commit "$target")"
        hbox_git log --oneline --no-decorate "$previous..$target" 2>/dev/null | head -n 30 | sed 's/^/    /' >&2
    fi

    if backup_configured && [ "$skip_backup" = 0 ]; then
        log "Backing up before updating"
        backup_run
    elif [ "$skip_backup" = 0 ]; then
        warn "Backups are not configured, so this update has no safety net."
        confirm "Update without a backup?" || die "Update cancelled."
    fi

    checkout_target "$target" >/dev/null
    # The CLI itself may have changed: continue with the new version.
    if [ "$previous" != "$target" ] && [ -z "${HBOX_UPDATE_REEXEC:-}" ]; then
        HBOX_UPDATE_REEXEC=1 HBOX_UPDATE_FROM=$previous exec "$HBOX_HOME/scripts/hbox" update --skip-backup --apply-only
    fi
    apply_revision
    log "Update complete: HBOX $(hbox_revision)."
}

# Second half of an update, run by the new CLI after checkout.
cmd_update_apply_only() {
    require_root
    exec 8>/run/hbox-update.lock
    flock -n 8 || true
    apply_revision
    log "Update complete: HBOX $(hbox_revision)."
}

cmd_rollback() {
    require_root
    require_docker
    require_env
    hbox_is_git || die "This installation is not a git checkout; nothing to roll back to."
    local target=${1:-}
    if [ -z "$target" ]; then
        [ -s "$HBOX_PREVIOUS_REV" ] || die "No previous HBOX version is recorded."
        target=$(cat "$HBOX_PREVIOUS_REV")
    fi
    target=$(hbox_git rev-parse --verify -q "$target^{commit}") || die "Unknown version: ${1:-}"
    require_clean_checkout
    cat >&2 <<EOF
Rolling back HBOX files to $(describe_commit "$target") (now $(hbox_revision)).
This restores HBOX's own files and app versions. Data and databases are not
changed: if an app already upgraded its database (rare, and named in the
release notes), restore the pre-update backup instead: sudo hbox backup restore
EOF
    confirm "Roll back?" || die "Cancelled."
    local current
    current=$(hbox_commit)
    hbox_git checkout -q --detach "$target"
    printf '%s' "$current" > "$HBOX_PREVIOUS_REV"
    HBOX_UPDATE_REEXEC=1 exec "$HBOX_HOME/scripts/hbox" update --skip-backup --apply-only
}
