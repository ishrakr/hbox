# shellcheck shell=bash
# Disk health (SMART) for the dashboard and doctor: servers installed before
# v1.0.2 lack smartmontools.
if ! command -v smartctl >/dev/null 2>&1; then
    log "  Installing smartmontools (disk health)"
    NEEDRESTART_SUSPEND=1 DEBIAN_FRONTEND=noninteractive \
        apt-get install -y -q --no-install-recommends smartmontools >/dev/null ||
        warn "Could not install smartmontools; disk health is not shown."
fi
