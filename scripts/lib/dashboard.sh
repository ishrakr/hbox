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

cmd_dashboard_actions() {
    require_root
    local want_check=0 want_update=0
    [ -e "$HBOX_REQUESTS_DIR/check" ] && want_check=1
    [ -e "$HBOX_REQUESTS_DIR/update" ] && want_update=1
    # Clear the requests first: a press while this runs starts a new run.
    rm -f -- "$HBOX_REQUESTS_DIR"/* 2>/dev/null || true

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
