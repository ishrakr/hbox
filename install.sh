#!/usr/bin/env bash
# HBOX installer for Ubuntu (22.04, 24.04+) and Debian (12, 13).
#
#   curl -fsSL https://raw.githubusercontent.com/ishrakr/hbox/main/install.sh | sudo bash
#
# or, from a checkout:   sudo ./install.sh [hbox setup options]
#
# Installs Docker Engine, restic and avahi, places HBOX in /opt/hbox, then runs
# `hbox setup`. Safe to re-run: existing configuration and data are reused.
set -Eeuo pipefail

HBOX_REPO=${HBOX_REPO:-https://github.com/ishrakr/hbox.git}
HBOX_REF=${HBOX_REF:-main}
HBOX_HOME=${HBOX_HOME:-/opt/hbox}
RESTIC_VERSION=0.19.1
declare -A RESTIC_SHA256=(
    [amd64]=f415415624dcc452f2a02b8c33641791a8c6d6d3b65bbb3543fcf9a25151585c
    [arm64]=a5f64aaab53d51e311fa3829124c5b703f2d14cf187d8640b6be3b2b49376465
)

log() { printf '\033[32m==>\033[0m %s\n' "$*" >&2; }
die() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: sudo ./install.sh [options]

Installer options:
  --dir PATH         Install HBOX here (default /opt/hbox)
  --ref REF          Git branch or tag to install and follow (default main;
                     "stable" = newest release tag)
  --skip-setup       Install prerequisites and files only; run `hbox setup` later

All other options are passed to `hbox setup` (see: hbox setup --help), e.g.
  --data-root /srv/hbox  --timezone Europe/Berlin  --admin-user ishrak
  --migrate              adopt an existing hbox-apps deployment's data
EOF
}

SKIP_SETUP=0
SETUP_ARGS=()
while [ "$#" -gt 0 ]; do
    case $1 in
        --dir) HBOX_HOME=$2; shift 2 ;;
        --ref) HBOX_REF=$2; shift 2 ;;
        --skip-setup) SKIP_SETUP=1; shift ;;
        -h | --help) usage; exit 0 ;;
        *) SETUP_ARGS+=("$1"); shift ;;
    esac
done

[ "$(id -u)" -eq 0 ] || die "Run the installer as root (sudo)."
[ -r /etc/os-release ] || die "Cannot detect the operating system."
# shellcheck disable=SC1091
. /etc/os-release

case ${ID:-} in
    ubuntu)
        [ "${VERSION_ID%%.*}" -ge 22 ] 2>/dev/null || die "Ubuntu 22.04 or newer is required (found $VERSION_ID)."
        ;;
    debian)
        [ "${VERSION_ID:-0}" -ge 12 ] 2>/dev/null || die "Debian 12 or newer is required (found ${VERSION_ID:-unknown})."
        ;;
    *) die "Unsupported system '${PRETTY_NAME:-unknown}'. HBOX supports Ubuntu 22.04+ and Debian 12+." ;;
esac

ARCH=$(dpkg --print-architecture)
case $ARCH in
    amd64 | arm64) ;;
    *) die "Unsupported CPU architecture: $ARCH (amd64 and arm64 are supported)." ;;
esac

[ "$(cat /proc/1/comm 2>/dev/null)" = systemd ] || die "HBOX requires systemd."
mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
[ "$mem_kb" -ge 3500000 ] || log "Warning: less than 4 GB RAM. Photos (Immich) needs at least 4 GB to run well."

export DEBIAN_FRONTEND=noninteractive
apt_install() {
    apt-get install -y -q --no-install-recommends "$@" >/dev/null
}

log "Installing base packages"
apt-get update -q >/dev/null
apt_install ca-certificates curl git gnupg openssl bzip2 avahi-daemon avahi-utils \
    iproute2 jq util-linux apache2-utils fdisk e2fsprogs exfatprogs smartmontools

if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
    log "Installing Docker Engine from download.docker.com"
    for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
        if dpkg -s "$pkg" >/dev/null 2>&1; then
            die "Package '$pkg' conflicts with Docker Engine. Remove it first (apt-get remove $pkg)."
        fi
    done
    install -d -m 0755 /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/$ID/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' \
        "$ARCH" "$ID" "${VERSION_CODENAME:?}" > /etc/apt/sources.list.d/docker.list
    apt-get update -q >/dev/null
    apt_install docker-ce docker-ce-cli containerd.io docker-compose-plugin
fi
systemctl enable --now docker >/dev/null
docker info >/dev/null 2>&1 || die "Docker did not start (see: journalctl -u docker)."

if ! command -v restic >/dev/null 2>&1 ||
    [ "$(restic version 2>/dev/null | awk '{print $2}')" != "$RESTIC_VERSION" ]; then
    log "Installing restic $RESTIC_VERSION"
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    curl -fsSL -o "$tmp/restic.bz2" \
        "https://github.com/restic/restic/releases/download/v$RESTIC_VERSION/restic_${RESTIC_VERSION}_linux_${ARCH}.bz2"
    echo "${RESTIC_SHA256[$ARCH]}  $tmp/restic.bz2" | sha256sum -c --quiet - ||
        die "restic download failed its checksum verification."
    bunzip2 "$tmp/restic.bz2"
    install -m 755 "$tmp/restic" /usr/local/bin/restic
fi

SOURCE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)
# Copy the program files of a local checkout, never its secrets or local state.
copy_checkout() {
    install -d -m 755 "$HBOX_HOME"
    tar -C "$SOURCE_DIR" --exclude=./.git --exclude=./.env --exclude='./stacks/*/.env' \
        --exclude=./manager/.env --exclude='./certs/*.key' --exclude='./certs/*.crt' \
        --exclude=./ca --exclude=./data --exclude=./local -cf - . | tar -C "$HBOX_HOME" -xf -
}
if [ -n "$SOURCE_DIR" ] && [ -f "$SOURCE_DIR/scripts/hbox" ] && [ -d "$SOURCE_DIR/stacks" ] &&
    [ "$(readlink -f "$SOURCE_DIR")" != "$(readlink -f "$HBOX_HOME")" ] &&
    [ ! -d "$HBOX_HOME/.git" ]; then
    # Installing from a local copy; `hbox update` links it to $HBOX_REPO later.
    log "Installing HBOX from $SOURCE_DIR to $HBOX_HOME"
    copy_checkout
elif [ -d "$HBOX_HOME/.git" ]; then
    log "HBOX is already installed in $HBOX_HOME (update it with: sudo hbox update)"
elif [ -f "$HBOX_HOME/scripts/hbox" ]; then
    log "Using the existing HBOX files in $HBOX_HOME"
else
    log "Downloading HBOX ($HBOX_REF) to $HBOX_HOME"
    git clone -q "$HBOX_REPO" "$HBOX_HOME"
    if [ "$HBOX_REF" = stable ]; then
        latest=$(git -C "$HBOX_HOME" tag -l 'v[0-9]*' --sort=-v:refname | head -n 1)
        [ -n "$latest" ] && git -C "$HBOX_HOME" checkout -q --detach "$latest"
    else
        git -C "$HBOX_HOME" checkout -q --detach "origin/$HBOX_REF" 2>/dev/null ||
            git -C "$HBOX_HOME" checkout -q --detach "$HBOX_REF"
    fi
fi
chmod 755 "$HBOX_HOME/scripts/hbox" "$HBOX_HOME/scripts/hbox-mdns" "$HBOX_HOME/scripts/generate-certs.sh"
ln -sfn "$HBOX_HOME/scripts/hbox" /usr/local/bin/hbox

if [ "$SKIP_SETUP" = 1 ]; then
    log "Prerequisites installed. Configure HBOX with: sudo hbox setup"
    exit 0
fi
export HBOX_HOME HBOX_REPO HBOX_REF
exec "$HBOX_HOME/scripts/hbox" setup "${SETUP_ARGS[@]}"
