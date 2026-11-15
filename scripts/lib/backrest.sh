# shellcheck shell=bash
# Backrest (https://github.com/garethgeorge/backrest): the web interface that
# runs and manages HBOX's restic backups. Sourced by the hbox CLI after
# common.sh and backup.sh.
#
# Backrest runs on the host (it needs to read /DATA and run the database dumps)
# as hbox-backrest.service, listening only on Docker's bridge address. nginx
# serves it over HTTPS on port 6443 and Backrest asks for the HBOX
# administrator login.
#
# HBOX keeps these parts of Backrest's configuration in line with the server,
# and leaves everything else (schedule, retention, notifications, extra plans)
# to whatever is set in Backrest:
#   - repository "hbox": the restic repository from `hbox backup setup`,
#   - plan "hbox": what to back up, plus hooks that dump the databases before
#     each snapshot and report the result to the dashboard,
#   - the administrator login.

HBOX_BACKREST_VERSION=1.14.1
declare -A HBOX_BACKREST_SHA256=(
    [amd64]=acc7835a9c55b3d254f0fa285cacbe87ac912cb7e069d0211924838020e6921c
    [arm64]=b53718cd6e042e7d99538cb652968ab966a5c53fabd556785648ceb13320a320
)
# Backrest's config format version for a new file (Backrest migrates it later).
HBOX_BACKREST_CONFIG_VERSION=6
HBOX_BACKREST_BIN=${HBOX_BACKREST_BIN:-/usr/local/bin/backrest}
HBOX_BACKREST_DIR=${HBOX_BACKREST_DIR:-$HBOX_ETC/backrest}
HBOX_BACKREST_CONFIG=$HBOX_BACKREST_DIR/config.json
HBOX_BACKREST_DATA=${HBOX_BACKREST_DATA:-$HBOX_STATE/backrest}
HBOX_BACKREST_PORT=9898
HBOX_BACKUPS_PORT=6443
HBOX_BACKREST_HOOK='/usr/local/bin/hbox backup hook'

backrest_version() {
    [ -x "$HBOX_BACKREST_BIN" ] || return 1
    "$HBOX_BACKREST_BIN" -version 2>/dev/null | sed -n 's/^backrest version: v\{0,1\}\([^,]*\),.*/\1/p'
}

# Download the pinned release and check it against its published checksum.
backrest_install() {
    local arch asset tmp
    if [ "$(backrest_version || true)" != "$HBOX_BACKREST_VERSION" ]; then
        arch=$(dpkg --print-architecture)
        case $arch in
            amd64) asset=x86_64 ;;
            arm64) asset=arm64 ;;
            *) die "Backrest is not available for $arch." ;;
        esac
        log "Installing Backrest $HBOX_BACKREST_VERSION"
        tmp=$(mktemp -d)
        if ! curl -fsSL --retry 3 -o "$tmp/backrest.tar.gz" \
            "https://github.com/garethgeorge/backrest/releases/download/v$HBOX_BACKREST_VERSION/backrest_Linux_$asset.tar.gz"; then
            rm -rf "$tmp"
            die "Could not download Backrest. Check the network and retry."
        fi
        if ! echo "${HBOX_BACKREST_SHA256[$arch]}  $tmp/backrest.tar.gz" | sha256sum -c --quiet - >/dev/null 2>&1; then
            rm -rf "$tmp"
            die "The Backrest download failed its checksum verification."
        fi
        tar -xzf "$tmp/backrest.tar.gz" -C "$tmp" backrest
        install -m 755 "$tmp/backrest" "$HBOX_BACKREST_BIN"
        rm -rf "$tmp"
    fi
    # htpasswd makes the bcrypt hash Backrest's login uses.
    if ! command -v htpasswd >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends apache2-utils >/dev/null ||
            die "Could not install apache2-utils (needed for the Backrest login)."
    fi
}

# Docker's default bridge address: reachable from containers (nginx reaches
# it as hbox-host, see stacks/hbox-core), but not from the network.
backrest_address() {
    local ip
    ip=$(docker network inspect bridge -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null | awk '{print $1}')
    printf '%s' "${ip:-172.17.0.1}"
}

backrest_url() {
    printf 'http://%s:%s' "$(backrest_address)" "$HBOX_BACKREST_PORT"
}

backrest_enabled() {
    backup_configured && [ -f "$HBOX_BACKREST_CONFIG" ] &&
        systemctl is-enabled --quiet hbox-backrest.service 2>/dev/null
}

backrest_answers() {
    curl -fsS -o /dev/null -m 5 "$(backrest_url)/" 2>/dev/null
}

# ExecStart of hbox-backrest.service.
cmd_backrest_run() {
    require_root
    local deadline=$((SECONDS + 120))
    # The bridge address exists once Docker is up.
    until docker network inspect bridge >/dev/null 2>&1; do
        [ "$SECONDS" -ge "$deadline" ] && die "Docker is not running."
        sleep 2
    done
    install -d -m 700 "$HBOX_BACKREST_DATA" "$HBOX_RESTIC_CACHE"
    # Backrest restores to $HOME/Downloads unless told otherwise: put that on
    # the data disk (DATA_ROOT/restores/Downloads), not the system disk.
    HOME=$(env_get_default DATA_ROOT /DATA)/restores
    install -d -m 700 "$HOME"
    export HOME
    export BACKREST_CONFIG=$HBOX_BACKREST_CONFIG BACKREST_DATA=$HBOX_BACKREST_DATA
    export BACKREST_RESTIC_COMMAND=/usr/local/bin/restic RESTIC_CACHE_DIR=$HBOX_RESTIC_CACHE
    # Backrest must use the password from its repository settings only.
    unset RESTIC_PASSWORD RESTIC_PASSWORD_FILE RESTIC_PASSWORD_COMMAND
    exec "$HBOX_BACKREST_BIN" -bind-address "$(backrest_address):$HBOX_BACKREST_PORT"
}

# Call Backrest's API (Connect protocol, JSON) with the administrator login.
backrest_api() {
    local method=$1 body=${2:-'{}'} timeout=${3:-30} user password
    user=$(env_get ADMIN_USER "$HBOX_CREDENTIALS")
    password=$(env_get ADMIN_PASSWORD "$HBOX_CREDENTIALS")
    curl -sS -m "$timeout" -K - -X POST -H 'Content-Type: application/json' \
        --data "$body" -w '\n%{http_code}' "$(backrest_url)/v1.Backrest/$method" <<EOF
user = "$user:$password"
EOF
}

# bcrypt hash of the administrator password, as Backrest stores it. Remade
# only when the password changes (bcrypt is salted, so the text always differs).
backrest_password_hash() {
    local password=$1 stamp=$HBOX_BACKREST_DIR/.login current
    current=$(printf '%s' "$password" | sha256sum | cut -d' ' -f1)
    if [ -f "$stamp" ] && [ "$(sed -n 1p "$stamp")" = "$current" ]; then
        sed -n 2p "$stamp"
        return 0
    fi
    local hash
    hash=$(printf '%s' "$password" | htpasswd -niBC 10 hbox | cut -d: -f2- | tr -d '\n' | base64 -w0)
    printf '%s\n%s\n' "$current" "$hash" > "$stamp"
    chmod 600 "$stamp"
    printf '%s' "$hash"
}

# Restic's repository id, which Backrest calls the repository's guid.
backrest_repo_guid() {
    local guid
    guid=$(run_restic cat config --json 2>/dev/null | jq -r '.id // empty') || true
    if [ -z "$guid" ] && [ -f "$HBOX_BACKREST_CONFIG" ]; then
        # The disk may be unplugged right now; keep the known id.
        guid=$(jq -r '.repos[]? | select(.id == "hbox") | .guid // empty' "$HBOX_BACKREST_CONFIG")
    fi
    [[ $guid =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s' "$guid"
}

# Restic environment for Backrest: the password file plus backend credentials
# from backup.env (never HBOX's own settings).
backrest_repo_env() {
    {
        printf 'RESTIC_PASSWORD_FILE=%s\n' "$HBOX_RESTIC_PASSWORD_FILE"
        grep -E '^[A-Z][A-Z0-9_]*=' "$HBOX_BACKUP_ENV" |
            grep -Ev '^(RESTIC_REPOSITORY|RESTIC_PASSWORD[A-Z_]*|KEEP_[A-Z]+|CHECK_[A-Z_]+|HBOX_[A-Z_]+)=' |
            while IFS= read -r line; do
                printf '%s=%s\n' "${line%%=*}" "$(env_get "${line%%=*}" "$HBOX_BACKUP_ENV")"
            done
    } | jq -R . | jq -sc 'sort'
}

# The configuration HBOX wants, merged into Backrest's current one.
backrest_render_config() {
    local current=$1 user password hash guid paths excludes flags env hooks
    user=$(env_get ADMIN_USER "$HBOX_CREDENTIALS")
    password=$(env_get ADMIN_PASSWORD "$HBOX_CREDENTIALS")
    [ -n "$user" ] && [ -n "$password" ] || die "The administrator login is missing from $HBOX_CREDENTIALS."
    hash=$(backrest_password_hash "$password")
    guid=$(backrest_repo_guid) ||
        die "Cannot open the backup repository ($(env_get RESTIC_REPOSITORY "$HBOX_BACKUP_ENV")). Is the backup disk connected?"
    paths=$(backup_paths | jq -R . | jq -sc .)
    excludes=$(backup_excludes | jq -R . | jq -sc .)
    flags=$(jq -nc --arg host "$(hostname -s)" '["--one-file-system", "--tag hbox", "--host \($host)"]')
    env=$(backrest_repo_env)
    hooks=$(jq -nc --arg hook "$HBOX_BACKREST_HOOK" '[
        {conditions: ["CONDITION_SNAPSHOT_START"], onError: "ON_ERROR_FATAL",
         actionCommand: {command: "\($hook) start"}},
        {conditions: ["CONDITION_SNAPSHOT_SUCCESS"],
         actionCommand: {command: "\($hook) success"}},
        {conditions: ["CONDITION_SNAPSHOT_WARNING"],
         actionCommand: {command: "\($hook) warning"}},
        {conditions: ["CONDITION_SNAPSHOT_ERROR"],
         actionCommand: {command: "\($hook) failed"}}]')
    printf '%s' "$current" | jq \
        --argjson version "$HBOX_BACKREST_CONFIG_VERSION" \
        --arg user "$user" --arg hash "$hash" \
        --arg uri "$(env_get RESTIC_REPOSITORY "$HBOX_BACKUP_ENV")" --arg guid "$guid" \
        --argjson env "$env" --argjson paths "$paths" --argjson excludes "$excludes" \
        --argjson flags "$flags" --argjson hooks "$hooks" --arg hook "$HBOX_BACKREST_HOOK" \
        --argjson daily "$(env_get_default KEEP_DAILY 7 "$HBOX_BACKUP_ENV")" \
        --argjson weekly "$(env_get_default KEEP_WEEKLY 4 "$HBOX_BACKUP_ENV")" \
        --argjson monthly "$(env_get_default KEEP_MONTHLY 12 "$HBOX_BACKUP_ENV")" \
        --argjson yearly "$(env_get_default KEEP_YEARLY 2 "$HBOX_BACKUP_ENV")" \
        --argjson subset "$(env_get_default CHECK_READ_DATA_SUBSET 5% "$HBOX_BACKUP_ENV" | tr -dc 0-9.)" \
        --arg notify "$(env_get_default HBOX_BACKUP_NOTIFY_URL '' "$HBOX_BACKUP_ENV")" '
        def ours: ((.actionCommand.command // "") | startswith($hook));
        (.version //= $version)
        | (if (.instance // "") == "" then .instance = "hbox" else . end)
        | .auth = {disabled: false,
                   users: ([.auth.users[]? | select(.name != $user)] + [{name: $user, passwordBcrypt: $hash}])}
        | .repos = ((.repos // []) as $repos
            | if any($repos[]; .id == "hbox") then
                $repos | map(if .id == "hbox"
                    then .uri = $uri | .guid = $guid | .env = $env | .autoUnlock = true
                         | del(.password, .autoInitialize)
                    else . end)
              else $repos + [{
                id: "hbox", uri: $uri, guid: $guid, env: $env, autoUnlock: true,
                prunePolicy: {schedule: {maxFrequencyDays: 7, clock: "CLOCK_LAST_RUN_TIME"},
                              maxUnusedPercent: 10},
                checkPolicy: {schedule: {maxFrequencyDays: 7, clock: "CLOCK_LAST_RUN_TIME"},
                              readDataSubsetPercent: $subset},
                commandPrefix: {ioNice: "IO_IDLE", cpuNice: "CPU_LOW"}}]
              end)
        | .plans = ((.plans // []) as $plans
            | if any($plans[]; .id == "hbox") then
                $plans | map(if .id == "hbox"
                    then .repo = "hbox" | .paths = $paths | .excludes = $excludes
                         | .backup_flags = $flags
                         | .hooks = ([.hooks[]? | select(ours | not)] + $hooks)
                    else . end)
              else $plans + [{
                id: "hbox", repo: "hbox", paths: $paths, excludes: $excludes,
                backup_flags: $flags,
                schedule: {cron: "0 3 * * *", clock: "CLOCK_LOCAL"},
                retention: {policyTimeBucketed: {daily: $daily, weekly: $weekly,
                                                 monthly: $monthly, yearly: $yearly}},
                hooks: ($hooks + (if $notify == "" then [] else [{
                    conditions: ["CONDITION_SNAPSHOT_SUCCESS", "CONDITION_SNAPSHOT_WARNING",
                                 "CONDITION_SNAPSHOT_ERROR", "CONDITION_ANY_ERROR"],
                    actionHealthchecks: {webhookUrl: $notify}}] end))}]
              end)'
}

# Bring Backrest in line with the backup settings: install it, write its
# configuration, and run it (or stop it when backups are not set up).
backrest_sync() {
    if ! backup_configured; then
        systemctl disable --now hbox-backrest.service >/dev/null 2>&1 || true
        return 0
    fi
    require_docker
    backrest_install
    install -d -m 700 "$HBOX_BACKREST_DIR" "$HBOX_BACKREST_DATA"
    local current='{}' desired restart=0
    if [ -s "$HBOX_BACKREST_CONFIG" ]; then
        current=$(cat "$HBOX_BACKREST_CONFIG")
    fi
    desired=$(backrest_render_config "$current") || return 1
    if [ "$(printf '%s' "$current" | jq -S .)" != "$(printf '%s' "$desired" | jq -S .)" ]; then
        restart=1
        # Backrest caches its configuration: stop it before changing the file.
        systemctl stop hbox-backrest.service >/dev/null 2>&1 || true
        local tmp
        tmp=$(mktemp "$HBOX_BACKREST_DIR/config.json.XXXXXX")
        printf '%s\n' "$desired" | jq '.modno = ((.modno // 0) + 1)' > "$tmp"
        chmod 600 "$tmp"
        mv -f "$tmp" "$HBOX_BACKREST_CONFIG"
    fi
    backrest_allow_firewall
    systemctl daemon-reload
    systemctl enable hbox-backrest.service >/dev/null
    if [ "$restart" = 1 ] || ! systemctl is-active --quiet hbox-backrest.service; then
        systemctl restart hbox-backrest.service
    fi
    if ! (wait_until 60 "Backrest" backrest_answers); then
        journalctl -u hbox-backrest -n 20 --no-pager >&2 || true
        die "Backrest did not start (above). See: journalctl -u hbox-backrest"
    fi
    if declare -F apps_render_dashboard >/dev/null; then
        apps_render_dashboard
    fi
}

# With ufw enabled, let nginx's container reach Backrest on the bridge.
backrest_allow_firewall() {
    command -v ufw >/dev/null 2>&1 || return 0
    ufw status 2>/dev/null | grep -q '^Status: active' || return 0
    ufw allow from 172.16.0.0/12 to "$(backrest_address)" port "$HBOX_BACKREST_PORT" proto tcp \
        comment 'HBOX Backups (nginx to Backrest)' >/dev/null 2>&1 || true
}

# Snapshots made by HBOX before Backrest ran its backups carry only the "hbox"
# tag; give them Backrest's plan tags so its retention policy covers them too.
backrest_adopt_snapshots() {
    local instance=hbox
    if [ -s "$HBOX_BACKREST_CONFIG" ]; then
        instance=$(jq -r '.instance // "hbox"' "$HBOX_BACKREST_CONFIG")
    fi
    run_restic tag --tag hbox --add "plan:hbox,created-by:$instance" >/dev/null 2>&1 || true
}

# Back up now through Backrest (it runs the hooks and records the history).
backrest_backup_now() {
    local response code
    log "Backing up (progress: https://$(primary_ip || echo hbox.local):$HBOX_BACKUPS_PORT/)"
    response=$(backrest_api Backup '{"value": "hbox"}' 0) || die "Could not reach Backrest."
    code=$(tail -n 1 <<<"$response")
    if [ "$code" != 200 ]; then
        # The start hook explains what went wrong in the backup status.
        if [ "$(env_get result "$HBOX_BACKUP_STATUS" 2>/dev/null)" = failed ]; then
            die "The backup failed: $(env_get detail "$HBOX_BACKUP_STATUS" 2>/dev/null)."
        fi
        die "The backup failed: $(sed '$d' <<<"$response" | jq -r '.message // .' 2>/dev/null | head -c 500). Details: https://$(primary_ip || echo hbox.local):$HBOX_BACKUPS_PORT/"
    fi
    if [ "$(env_get result "$HBOX_BACKUP_STATUS" 2>/dev/null)" = warning ]; then
        warn "Backup completed, but some files could not be read (see Backups for details)."
    else
        log "Backup completed."
    fi
}

# Facts for the dashboard: snapshot count, protected size and next run.
backrest_summary() {
    local response
    backrest_enabled || return 1
    response=$(backrest_api GetSummaryDashboard '{}' 10 2>/dev/null) || return 1
    [ "$(tail -n 1 <<<"$response")" = 200 ] || return 1
    # Backrest leaves totalSnapshots empty, so restic counts them: after each
    # backup and at most every 30 minutes (a cloud repository costs requests).
    local count cache=$HBOX_STATE/backup-snapshots
    if [ ! -s "$cache" ] || [ -n "$(find "$cache" -mmin +30 2>/dev/null)" ] ||
        { [ -f "$HBOX_BACKUP_STATUS" ] && [ "$HBOX_BACKUP_STATUS" -nt "$cache" ]; }; then
        if count=$(run_restic snapshots --tag hbox --json --no-lock 2>/dev/null | jq -e 'length' 2>/dev/null); then
            printf '%s\n' "$count" > "$cache"
        fi
    fi
    count=$(cat "$cache" 2>/dev/null || echo 0)
    [[ $count =~ ^[0-9]+$ ]] || count=0
    sed '$d' <<<"$response" | jq -c --argjson count "${count:-0}" '
        (.planSummaries // [] | map(select(.id == "hbox")) | first // {}) as $p
        | {snapshots: $count,
           protected: (($p.protectedBytes // "0") | tonumber),
           next: (if ($p.nextBackupTimeMs // "0" | tonumber) > 0
                  then (($p.nextBackupTimeMs | tonumber) / 1000 | floor | todate) else "" end)}'
}
