# shellcheck shell=bash
# Dashboard actions: the dashboard's "Check for updates" and "Update now"
# buttons. Sourced by the hbox CLI after common.sh and update.sh.
#
# nginx (unprivileged, no Docker access) can only drop an empty file into
# HBOX_REQUESTS_DIR/{check,update}; installing an update requires the HBOX
# administrator login (checked by nginx against HBOX_AUTH_DIR/htpasswd).
# hbox-dashboard.path notices the file and runs `hbox dashboard-actions`,
# which reports progress in HBOX_STATUS_DIR/update.json.

HBOX_REQUESTS_DIR=${HBOX_REQUESTS_DIR:-$HBOX_STATE/requests}
HBOX_AUTH_DIR=${HBOX_AUTH_DIR:-$HBOX_STATE/nginx-auth}
HBOX_UPDATE_LOG=$HBOX_STATE/update.log
# nginx's user id in the official image.
HBOX_NGINX_UID=101

# Folders nginx writes requests to and reads the login from.
dashboard_dirs() {
    # Group nginx (by number; the host may have no such group) may create
    # files but not list or read the folder.
    install -d -m 730 -o root -g "$HBOX_NGINX_UID" "$HBOX_REQUESTS_DIR"
    install -d -m 750 -o root -g "$HBOX_NGINX_UID" "$HBOX_AUTH_DIR"
    if [ ! -f "$HBOX_AUTH_DIR/htpasswd" ]; then
        install -m 640 -o root -g "$HBOX_NGINX_UID" /dev/null "$HBOX_AUTH_DIR/htpasswd"
    fi
    dashboard_sync_login
    [ -f "$HBOX_STATUS_DIR/update.json" ] || dashboard_progress idle ""
}

# The update button uses the HBOX administrator login (sudo hbox credentials).
dashboard_sync_login() {
    local user password hash tmp
    [ -f "$HBOX_CREDENTIALS" ] || return 0
    user=$(env_get ADMIN_USER "$HBOX_CREDENTIALS" 2>/dev/null) || return 0
    password=$(env_get ADMIN_PASSWORD "$HBOX_CREDENTIALS" 2>/dev/null) || return 0
    [ -n "$user" ] && [ -n "$password" ] || return 0
    # apr1 (salted, 1000 rounds of MD5) is the one scheme nginx verifies
    # itself on every platform; the 20-character random password and the
    # request rate limit make guessing impractical. The file is readable only
    # by root and nginx. Keep the hash while it matches, so it rarely changes.
    if [ -s "$HBOX_AUTH_DIR/htpasswd" ] &&
        hash=$(awk -F: -v u="$user" '$1 == u { print $2 }' "$HBOX_AUTH_DIR/htpasswd") &&
        [ -n "$hash" ] && [ "$(openssl passwd -apr1 -salt "$(cut -d'$' -f3 <<<"$hash")" -stdin <<<"$password")" = "$hash" ]; then
        return 0
    fi
    tmp=$(mktemp "$HBOX_AUTH_DIR/htpasswd.XXXXXX")
    printf '%s:%s\n' "$user" "$(openssl passwd -apr1 -stdin <<<"$password")" > "$tmp"
    chown "root:$HBOX_NGINX_UID" "$tmp"
    chmod 640 "$tmp"
    mv -f "$tmp" "$HBOX_AUTH_DIR/htpasswd"
}

# Progress for the dashboard: state is idle, checking, updating, done, failed.
dashboard_progress() {
    local state=$1 message=$2 tmp
    install -d -m 755 "$HBOX_STATUS_DIR"
    tmp=$(mktemp "$HBOX_STATUS_DIR/update.json.XXXXXX")
    jq -n --arg state "$state" --arg message "$message" \
        --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{state: $state, message: $message, time: $time}' > "$tmp"
    chmod 644 "$tmp"
    mv -f "$tmp" "$HBOX_STATUS_DIR/update.json"
}

# ---------------------------------------------------------------- power
# Power menu: restart or shut down the server, stop, start or restart the
# apps. Progress for the dashboard is in HBOX_STATUS_DIR/power.json.
HBOX_APPS_STOPPED=${HBOX_APPS_STOPPED:-$HBOX_STATE/apps-stopped}

power_progress() {
    local state=$1 message=$2 tmp
    install -d -m 755 "$HBOX_STATUS_DIR"
    tmp=$(mktemp "$HBOX_STATUS_DIR/power.json.XXXXXX")
    jq -n --arg state "$state" --arg message "$message" \
        --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{state: $state, message: $message, time: $time}' > "$tmp"
    chmod 644 "$tmp"
    mv -f "$tmp" "$HBOX_STATUS_DIR/power.json"
}

# Nothing that must not be cut off: an update, a backup (dumps or restic,
# also when Backrest runs it) or a restore. Waits up to 30 minutes.
power_wait_for_quiet() {
    local deadline=$((SECONDS + 1800)) said=0
    while ! flock -n /run/hbox-update.lock true 2>/dev/null ||
        ! flock -n /run/hbox-backup.lock true 2>/dev/null || pgrep -x restic >/dev/null; do
        if [ "$said" = 0 ]; then
            power_progress "$1" "Waiting for a running backup or update to finish…"
            said=1
        fi
        [ "$SECONDS" -ge "$deadline" ] && return 1
        sleep 5
    done
}

# The apps people use: Photos, Files and optional apps. The dashboard, Admin,
# Backups and remote access keep running.
power_stop_apps() {
    local name
    while IFS= read -r name; do
        app_dir "$name" >/dev/null && app_compose "$name" stop || true
    done < <(apps_enabled)
    stack_compose hbox-files stop
    stack_compose hbox-photos stop
    touch "$HBOX_APPS_STOPPED"
}

power_start_apps() {
    stack_up hbox-photos
    stack_up hbox-files
    apps_start_enabled
    rm -f "$HBOX_APPS_STOPPED"
}

power_action() {
    local action=$1 busy log=$HBOX_STATE/power.log
    case $action in
        restart) busy="Restarting the server…" ;;
        shutdown) busy="Shutting down…" ;;
        apps-restart) busy="Restarting the apps…" ;;
        apps-stop) busy="Stopping the apps…" ;;
        apps-start) busy="Starting the apps…" ;;
        *) return 0 ;;
    esac
    if ! power_wait_for_quiet "$action"; then
        power_progress failed "A backup or update is still running. Try again when it has finished."
        return 0
    fi
    power_progress "$action" "$busy"
    case $action in
        restart | shutdown)
            # Docker stops every container cleanly (databases flush to disk)
            # as the system shuts down, and its restart policy starts them
            # again at boot. Stopping them here instead would keep them off
            # after the restart. Apps stopped from this menu stay stopped.
            sync
            if [ "$action" = restart ]; then
                systemctl --no-block reboot
            else
                power_progress off "The server is off. Start it with its power button."
                systemctl --no-block poweroff
            fi
            ;;
        apps-stop)
            if (power_stop_apps) > "$log" 2>&1; then
                power_progress done "The apps are stopped. Start them from this menu."
            else
                power_progress failed "Stopping the apps failed; see $log on the server."
            fi
            ;;
        apps-start | apps-restart)
            if { [ "$action" = apps-start ] || (power_stop_apps); } > "$log" 2>&1 &&
                (power_start_apps) >> "$log" 2>&1; then
                power_progress done "The apps are running."
            else
                power_progress failed "Starting the apps failed; see $log on the server."
            fi
            ;;
    esac
    cmd_status_update 2>/dev/null || true
}

# After a restart, the dashboard learns that it is done.
power_after_boot() {
    local file=$HBOX_STATUS_DIR/power.json state time boot
    [ -f "$file" ] || return 0
    state=$(jq -r '.state // ""' "$file" 2>/dev/null)
    case $state in restart | shutdown | off) ;; *) return 0 ;; esac
    time=$(date -d "$(jq -r '.time' "$file")" +%s 2>/dev/null) || return 0
    # When systemd (PID 1) started: the boot, also inside a container.
    boot=$(( $(date +%s) - $(ps -o etimes= -p 1 | tr -dc 0-9) ))
    [ "$time" -lt "$boot" ] || return 0
    power_progress done "The server restarted at $(date -d "@$boot" +%H:%M)."
}

cmd_dashboard_actions() {
    require_root
    local want_check=0 want_update=0 power='' action
    [ -e "$HBOX_REQUESTS_DIR/check" ] && want_check=1
    [ -e "$HBOX_REQUESTS_DIR/update" ] && want_update=1
    # One power action at a time; the most drastic wins.
    for action in shutdown restart apps-stop apps-restart apps-start; do
        if [ -e "$HBOX_REQUESTS_DIR/$action" ]; then
            power=$action
            break
        fi
    done
    # Clear the requests first: a press while this runs starts a new run.
    rm -f -- "$HBOX_REQUESTS_DIR"/* 2>/dev/null || true

    if [ -n "$power" ]; then
        power_action "$power"
        return 0
    fi

    if [ "$want_update" = 1 ]; then
        dashboard_progress updating "Backing up and installing the update…"
        if (HBOX_ASSUME_YES=1 cmd_update --yes) > "$HBOX_UPDATE_LOG" 2>&1; then
            dashboard_progress "done" "Updated to $(hbox_revision)."
        else
            dashboard_progress failed "$(grep -E '^Error' "$HBOX_UPDATE_LOG" | tail -n 1 | sed 's/^Error: //' | cut -c1-300)"
        fi
        cmd_status_update 2>/dev/null || true
    elif [ "$want_check" = 1 ]; then
        dashboard_progress checking "Checking for updates…"
        if (cmd_update --check) > "$HBOX_UPDATE_LOG" 2>&1; then
            dashboard_progress idle ""
        else
            dashboard_progress failed "$(grep -E '^Error' "$HBOX_UPDATE_LOG" | tail -n 1 | sed 's/^Error: //' | cut -c1-300)"
        fi
    fi
}
