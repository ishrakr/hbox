# shellcheck shell=bash
# Shared helpers for the hbox CLI. Sourced, never executed directly.

HBOX_LIB_DIR=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)
HBOX_HOME=${HBOX_HOME:-$(cd -- "$HBOX_LIB_DIR/../.." && pwd)}
HBOX_ETC=${HBOX_ETC:-/etc/hbox}
HBOX_STATE=${HBOX_STATE:-/var/lib/hbox}
HBOX_ENV_FILE=${HBOX_ENV_FILE:-$HBOX_HOME/.env}
HBOX_SYSTEMD_DIR=${HBOX_SYSTEMD_DIR:-/etc/systemd/system}
HBOX_NETWORK=hbox-frontend
# Set by --yes options; read by confirm().
HBOX_ASSUME_YES=${HBOX_ASSUME_YES:-0}
export HBOX_ASSUME_YES
# Start order matters only for humans; nginx resolves upstreams at request time.
HBOX_CORE_STACKS=(hbox-core hbox-photos hbox-files)

if [ -t 2 ]; then
    C_RED=$'\e[31m' C_YELLOW=$'\e[33m' C_GREEN=$'\e[32m' C_BOLD=$'\e[1m' C_RESET=$'\e[0m'
else
    C_RED='' C_YELLOW='' C_GREEN='' C_BOLD='' C_RESET=''
fi

log() { printf '%s==>%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
warn() { printf '%sWarning:%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die() { printf '%sError:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }
heading() { printf '\n%s%s%s\n' "$C_BOLD" "$*" "$C_RESET" >&2; }

require_root() {
    [ "$(id -u)" -eq 0 ] || die "This command must run as root. Try: sudo hbox ${HBOX_COMMAND:-}"
}

require_docker() {
    command -v docker >/dev/null 2>&1 || die "Docker is not installed. Run the HBOX installer first."
    docker info >/dev/null 2>&1 || die "The Docker daemon is not running (try: sudo systemctl start docker)."
    docker compose version >/dev/null 2>&1 || die "The Docker Compose plugin is missing."
}

require_env() {
    [ -f "$HBOX_ENV_FILE" ] || die "HBOX is not configured ($HBOX_ENV_FILE is missing). Run the installer first."
}

# Read KEY from a dotenv-style file (default: HBOX's .env).
env_get() {
    local key=$1 file=${2:-$HBOX_ENV_FILE} line value
    [ -f "$file" ] || return 1
    line=$(grep -E "^${key}=" "$file" | tail -n 1) || return 1
    value=${line#*=}
    case $value in
        \"*\") value=${value#\"}; value=${value%\"} ;;
        \'*\') value=${value#\'}; value=${value%\'} ;;
    esac
    printf '%s\n' "$value"
}

env_get_default() {
    local value
    value=$(env_get "$1" "${3:-$HBOX_ENV_FILE}" 2>/dev/null) || value=''
    [ -n "$value" ] || value=$2
    printf '%s\n' "$value"
}

# Quote values so Docker Compose neither interpolates nor truncates them.
env_quote() {
    local value=$1
    if [[ $value =~ ^[A-Za-z0-9_./:@,+=%-]*$ ]]; then
        printf '%s' "$value"
    elif [[ $value != *"'"* && $value != *$'\n'* ]]; then
        printf "'%s'" "$value"
    else
        die "Values containing single quotes or newlines are not supported in env files."
    fi
}

# Set KEY=VALUE in a dotenv file (created mode 600), replacing any assignment.
env_set() {
    local key=$1 value file=${3:-$HBOX_ENV_FILE} tmp
    value=$(env_quote "$2")
    [ -f "$file" ] || install -m 600 /dev/null "$file"
    tmp=$(mktemp "$file.XXXXXX")
    K=$key V=$value awk '
        BEGIN { done = 0 }
        index($0, ENVIRON["K"] "=") == 1 { if (!done) print ENVIRON["K"] "=" ENVIRON["V"]; done = 1; next }
        { print }
        END { if (!done) print ENVIRON["K"] "=" ENVIRON["V"] }
    ' "$file" > "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$file"
}

random_secret() {
    # Alphanumeric only: safe for PostgreSQL, Compose and every app's config.
    openssl rand -hex 24
}

wait_until() {
    local timeout=$1 label=$2 deadline
    shift 2
    deadline=$((SECONDS + timeout))
    until "$@" >/dev/null 2>&1; do
        if [ "$SECONDS" -ge "$deadline" ]; then
            die "$label did not become ready within ${timeout}s. Inspect it with: sudo hbox logs"
        fi
        sleep 3
    done
}

primary_ip() {
    ip -4 route get 1.1.1.1 2>/dev/null |
        awk '{ for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit } }'
}

stack_dir() {
    case $1 in
        hbox-dockge) printf '%s/manager' "$HBOX_HOME" ;;
        *) printf '%s/stacks/%s' "$HBOX_HOME" "$1" ;;
    esac
}

stack_compose() {
    local stack=$1 dir
    shift
    dir=$(stack_dir "$stack")
    [ -f "$dir/compose.yaml" ] || die "Unknown stack: $stack"
    local files=(-f "$dir/compose.yaml")
    # Generated additions (e.g. optional apps' ports); Dockge loads it too.
    [ -f "$dir/compose.override.yaml" ] && files+=(-f "$dir/compose.override.yaml")
    docker compose --project-directory "$dir" "${files[@]}" \
        --env-file "$HBOX_ENV_FILE" "$@"
}

# Stacks HBOX manages, in start order. Tailscale is opt-in.
enabled_stacks() {
    printf '%s\n' "${HBOX_CORE_STACKS[@]}"
    if [ "$(env_get_default HBOX_ENABLE_TAILSCALE 0)" = 1 ]; then
        printf '%s\n' hbox-tailscale
    fi
}

container_running() {
    [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ]
}

container_healthy() {
    [ "$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$1" 2>/dev/null)" = healthy ]
}

occ() {
    docker exec -u abc nextcloud php /app/www/public/occ "$@"
}

nextcloud_installed() {
    occ status --output=json 2>/dev/null | grep -q '"installed":true'
}

ensure_network() {
    docker network inspect "$HBOX_NETWORK" >/dev/null 2>&1 ||
        docker network create "$HBOX_NETWORK" >/dev/null
}

confirm() {
    local prompt=$1 reply
    [ "${HBOX_ASSUME_YES:-0}" = 1 ] && return 0
    [ -t 0 ] || die "$prompt Re-run with --yes to confirm non-interactively."
    read -r -p "$prompt [y/N] " reply
    [[ $reply =~ ^[Yy]([Ee][Ss])?$ ]]
}
