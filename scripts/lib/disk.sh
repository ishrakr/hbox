# shellcheck shell=bash
# Backup disks: `hbox backup disk` turns an attached disk (USB or internal,
# empty or not) into HBOX's backup repository. Sourced after backup.sh.
#
# The disk is mounted by its filesystem UUID at HBOX_BACKUP_MOUNT_DEFAULT with
# "nofail", so the server boots without it, and it is mounted again before
# each backup after being unplugged. While it is missing, the mount point is
# immutable, so nothing is ever written to the system disk by mistake.

HBOX_BACKUP_MOUNT_DEFAULT=${HBOX_BACKUP_MOUNT_DEFAULT:-/mnt/hbox-backup}
HBOX_BACKUP_LABEL=HBOX-BACKUP
# Filesystems a disk may keep (with --keep); others must be formatted.
HBOX_KEEP_FILESYSTEMS=" ext4 xfs btrfs exfat "
# Smallest disk offered for backups (bytes).
HBOX_BACKUP_MIN_SIZE=$((8 * 1000 * 1000 * 1000))

disk_tools() {
    local missing=()
    command -v sfdisk >/dev/null 2>&1 || missing+=(fdisk)
    command -v mkfs.ext4 >/dev/null 2>&1 || missing+=(e2fsprogs)
    command -v mkfs.exfat >/dev/null 2>&1 || missing+=(exfatprogs)
    [ "${#missing[@]}" -eq 0 ] && return 0
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "${missing[@]}" >/dev/null ||
        die "Could not install ${missing[*]}."
}

# Every disk as JSON: name, path, size, model, transport, and, collected over
# its partitions, what is on it.
disk_inventory() {
    local mount current probed='{}' dev
    mount=$(env_get_default HBOX_BACKUP_MOUNT '' "$HBOX_BACKUP_ENV" 2>/dev/null || true)
    current=$(disk_current_mount)
    # lsblk shows what udev has recorded, which can lag for a disk that was
    # just attached; read the filesystems from the disks themselves too.
    udevadm trigger --subsystem-match=block --action=change >/dev/null 2>&1 || true
    udevadm settle >/dev/null 2>&1 || true
    while IFS= read -r dev; do
        probed=$(blkid -o export "$dev" 2>/dev/null |
            jq -Rn --arg dev "$dev" --argjson acc "$probed" '
                [inputs | select(contains("=")) | {key: .[:index("=")], value: .[index("=") + 1:]}] | from_entries
                | if .TYPE then $acc + {($dev): {fstype: .TYPE, label: .LABEL, uuid: .UUID}} else $acc end') || true
    done < <(lsblk -lnpo PATH 2>/dev/null)
    lsblk -J -b -o NAME,PATH,TYPE,SIZE,MODEL,VENDOR,TRAN,RM,RO,FSTYPE,LABEL,UUID,PTTYPE,MOUNTPOINTS 2>/dev/null |
        jq --argjson probed "$probed" '
            def fill: (if .fstype == null and $probed[.path] then . + $probed[.path] else . end)
                      | if .children then .children |= map(fill) else . end;
            .blockdevices |= map(fill)' |
        jq -c --arg mount "${mount:-$HBOX_BACKUP_MOUNT_DEFAULT}" --arg current "$current" \
            --arg loop "${HBOX_BACKUP_ALLOW_LOOP:-0}" '
        def nodes: ., (.children[]? | nodes);
        [.blockdevices[]
         | select(.type == "disk" or ($loop == "1" and .type == "loop"))
         | select((.name | test("^(zram|nbd|ram|mmcblk[0-9]+boot)")) | not)
         | . as $disk
         | [nodes] as $all
         | ([$all[] | .mountpoints[]? | select(. != null and . != "")]) as $mounts
         | {name, path, size, ro,
            model: ([.vendor, .model] | map(select(. != null) | gsub("^\\s+|\\s+$"; "")) | map(select(. != "")) | join(" ")),
            usb: (.tran == "usb" or .rm == true),
            mounts: $mounts,
            filesystems: [$all[] | select(.fstype != null) | {path, fstype, label, uuid, type}],
            hbox: (any($all[]; .label == "HBOX-BACKUP") or any($mounts[]; . == $mount)),
            current: ($current != "" and any($mounts[]; . == $current)),
            system: (any($mounts[]; . != $mount and . != $current and (startswith($mount + "/") | not))
                     or any($all[]; (.fstype // "") | test("^(swap|LVM2_member|linux_raid_member|crypto_LUKS|zfs_member|bcache)$"))),
            empty: (($all | length) == 1 and .fstype == null and .pttype == null)}]'
}

# Where the disk holding the current repository is mounted, when HBOX did not
# mount it (set up before HBOX, or by hand): such a disk can be taken over.
disk_current_mount() {
    local repo target
    [ -z "$(env_get_default HBOX_BACKUP_MOUNT '' "$HBOX_BACKUP_ENV" 2>/dev/null || true)" ] || return 0
    repo=$(env_get RESTIC_REPOSITORY "$HBOX_BACKUP_ENV" 2>/dev/null || true)
    [[ $repo == /* ]] && [ -d "$repo" ] || return 0
    target=$(findmnt -no TARGET -T "$repo" 2>/dev/null) || return 0
    [ -n "$target" ] && [ "$target" != / ] || return 0
    printf '%s' "$target"
}

# ---------------------------------------------------------------- health
# The drives' own health reports (SMART), for the dashboard and doctor:
# the disks holding the system, the data and the backups. Checked at most
# hourly, and never waking a sleeping backup disk (its last result is kept).
HBOX_DISK_HEALTH=${HBOX_DISK_HEALTH:-$HBOX_STATE/disk-health.json}

# Physical disks under a mounted path (all of them for LVM or RAID).
disk_physical() {
    local source
    source=$(findmnt -no SOURCE -T "$1" 2>/dev/null | sed 's/\[.*//') || return 0
    [ -b "$source" ] || return 0
    lsblk -snpo PATH,TYPE "$source" 2>/dev/null | awk '$2 == "disk" {print $1}'
}

# One disk as JSON: status ok, warning, failing, asleep or unsupported.
disk_health_one() {
    local device=$1 role=$2 json rc=0
    json=$(smartctl -n standby,7 -H -A -i -j "$device" 2>/dev/null) || rc=$?
    if [ "$rc" = 7 ]; then
        jq -nc --arg p "$device" --arg r "$role" '{path: $p, role: $r, status: "asleep"}'
        return
    fi
    # Bits 0-1: smartctl could not run or open the disk (virtual disks).
    if [ $((rc & 3)) -ne 0 ] || ! jq -e . >/dev/null 2>&1 <<<"$json"; then
        jq -nc --arg p "$device" --arg r "$role" '{path: $p, role: $r, status: "unsupported"}'
        return
    fi
    jq -c --arg p "$device" --arg r "$role" '
        def raw($id): ([.ata_smart_attributes.table[]? | select(.id == $id) | .raw.value][0] // 0);
        (.nvme_smart_health_information_log // {}) as $n
        | [ (if .smart_status.passed == false then "the drive reports that it is failing" else empty end),
            (if ($n.critical_warning // 0) != 0 then "the drive reports a critical warning" else empty end),
            (if $n.available_spare != null and $n.available_spare_threshold != null
                and $n.available_spare < $n.available_spare_threshold then "its spare blocks are used up" else empty end)
          ] as $failing
        | [ (raw(5) | if . > 0 then "\(.) reallocated sectors" else empty end),
            (raw(197) | if . > 0 then "\(.) sectors waiting to be reallocated" else empty end),
            (raw(198) | if . > 0 then "\(.) unreadable sectors" else empty end),
            (($n.media_errors // 0) | if . > 0 then "\(.) media errors" else empty end),
            (($n.percentage_used // 0) | if . >= 90 then "\(.)% of its rated life used" else empty end)
          ] as $warnings
        | {path: $p, role: $r, model: (.model_name // ""),
           temperature: .temperature.current, hours: .power_on_time.hours,
           status: (if .smart_status == null and ($n | length) == 0 then "unsupported"
                    elif ($failing | length) > 0 then "failing"
                    elif ($warnings | length) > 0 then "warning"
                    else "ok" end),
           problems: ($failing + $warnings)}' <<<"$json"
}

# Refresh the cached results when older than an hour (or with "now").
disk_health_refresh() {
    local force=${1:-} age=999999 data mount entries=() device role previous='{}' line
    command -v smartctl >/dev/null 2>&1 || return 0
    if [ -s "$HBOX_DISK_HEALTH" ]; then
        age=$(( $(date +%s) - $(stat -c %Y "$HBOX_DISK_HEALTH") ))
        previous=$(cat "$HBOX_DISK_HEALTH")
    fi
    [ "$force" = now ] || [ "$age" -ge 3600 ] || return 0
    data=$(env_get_default DATA_ROOT /DATA 2>/dev/null || echo /DATA)
    mount=$(env_get_default HBOX_BACKUP_MOUNT '' "$HBOX_BACKUP_ENV" 2>/dev/null || true)
    declare -A roles=()
    while IFS= read -r device; do roles[$device]=server; done < <(disk_physical / ; disk_physical "$data")
    if [ -n "$mount" ] && mountpoint -q "$mount"; then
        while IFS= read -r device; do roles[$device]=backup; done < <(disk_physical "$mount")
    fi
    for device in "${!roles[@]}"; do
        line=$(disk_health_one "$device" "${roles[$device]}")
        # A sleeping disk keeps its last result.
        if [ "$(jq -r .status <<<"$line")" = asleep ]; then
            line=$(jq -c --arg p "$device" --argjson now "$line" \
                '[.disks[]? | select(.path == $p)][0] // $now' <<<"$previous")
        fi
        entries+=("$line")
    done
    printf '%s\n' "${entries[@]}" | jq -s --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{checked: $t, disks: (map(select(. != null)) | sort_by(.role, .path))}' > "$HBOX_DISK_HEALTH.tmp" &&
        mv -f "$HBOX_DISK_HEALTH.tmp" "$HBOX_DISK_HEALTH"
}

disk_state() {
    jq -r --argjson min "$HBOX_BACKUP_MIN_SIZE" '
        if .system then "in use by this server"
        elif .ro then "read-only"
        elif .size < $min then "too small"
        elif .current then "holds this server'"'"'s backups"
        elif .hbox then "HBOX backup disk"
        elif .empty then "empty"
        else "has data (" + ([.filesystems[] | .fstype + (if .label then " \"" + .label + "\"" else "" end)] | unique | join(", ") | if . == "" then "unknown" else . end) + ")"
        end' <<<"$1"
}

disk_usable() {
    jq -e --argjson min "$HBOX_BACKUP_MIN_SIZE" '(.system or .ro or .size < $min) | not' <<<"$1" >/dev/null
}

disk_human_size() {
    numfmt --to=si --round=nearest --suffix=B --format='%.0f' "$1" 2>/dev/null || printf '%s bytes' "$1"
}

disk_list() {
    local inventory disk n=0
    inventory=$(disk_inventory)
    printf '  %-3s %-14s %-8s %-5s %-28s %s\n' '#' DISK SIZE USB MODEL STATE
    while IFS= read -r disk; do
        n=$((n + 1))
        printf '  %-3s %-14s %-8s %-5s %-28s %s\n' "$n" "$(jq -r .path <<<"$disk")" \
            "$(disk_human_size "$(jq -r .size <<<"$disk")")" \
            "$(jq -r 'if .usb then "yes" else "-" end' <<<"$disk")" \
            "$(jq -r '.model | if . == "" then "-" else .[0:28] end' <<<"$disk")" \
            "$(disk_state "$disk")"
    done < <(jq -c '.[]' <<<"$inventory")
    [ "$n" -gt 0 ] || echo "  (no disks found)"
}

# The disk named by /dev/sdb, sdb, a number from the list, or a partition.
disk_find() {
    local want=$1 inventory parent
    inventory=$(disk_inventory)
    if [[ $want =~ ^[0-9]+$ ]]; then
        jq -ce --argjson n "$want" '.[$n - 1] // empty' <<<"$inventory" && return 0
    fi
    [[ $want == /* ]] || want=/dev/$want
    want=$(readlink -f "$want" 2>/dev/null || printf '%s' "$want")
    if ! jq -ce --arg p "$want" '.[] | select(.path == $p)' <<<"$inventory"; then
        # A partition: use its disk.
        parent=$(lsblk -no PKNAME "$want" 2>/dev/null | head -n 1)
        [ -n "$parent" ] || return 1
        jq -ce --arg p "/dev/$parent" '.[] | select(.path == $p)' <<<"$inventory"
    fi
}

# Erase DISK and create one ext4 partition labelled HBOX-BACKUP.
disk_format() {
    local path=$1 part
    log "Erasing $path and creating an HBOX backup filesystem"
    # Partitions first, so no old signature can resurface.
    lsblk -lnpo PATH,TYPE "$path" | awk '$2 == "part" {print $1}' | xargs -r wipefs -a -q
    wipefs -a -q "$path"
    printf 'label: gpt\n,,L\n' | sfdisk -q --wipe always --wipe-partitions always "$path" >/dev/null ||
        die "Could not partition $path."
    udevadm settle 2>/dev/null || true
    partprobe "$path" 2>/dev/null || blockdev --rereadpt "$path" 2>/dev/null || true
    udevadm settle 2>/dev/null || true
    part=$(lsblk -lnpo PATH,TYPE "$path" | awk '$2 == "part" {print $1; exit}')
    [ -n "$part" ] && [ -b "$part" ] || die "The new partition on $path did not appear."
    # No reserved blocks: root never needs space on a backup disk.
    mkfs.ext4 -q -F -m 0 -L "$HBOX_BACKUP_LABEL" "$part" >/dev/null || die "Could not create a filesystem on $part."
    udevadm settle 2>/dev/null || true
    printf '%s' "$part"
}

# Mount DEVICE (by UUID) at MOUNT now and at every boot, without making the
# boot wait for it.
disk_mount() {
    local device=$1 mount=$2 uuid fstype pass=2 options=defaults,noatime,nofail,x-systemd.device-timeout=10s
    uuid=$(blkid -s UUID -o value "$device")
    fstype=$(blkid -s TYPE -o value "$device")
    [ -n "$uuid" ] && [ -n "$fstype" ] || die "$device has no filesystem."
    [ "$fstype" = exfat ] && pass=0

    if mountpoint -q "$mount"; then
        [ "$(findmnt -no SOURCE "$mount" | xargs -r readlink -f)" = "$(readlink -f "$device")" ] ||
            die "$mount is already used by another disk ($(findmnt -no SOURCE "$mount"))."
    fi
    # Mounted elsewhere (desktop automount)? Mount it at HBOX's place.
    local target
    while IFS= read -r target; do
        [ "$target" = "$mount" ] || umount "$target" || die "$device is in use at $target; close it and retry."
    done < <(findmnt -rno TARGET "$device" 2>/dev/null)

    install -d -m 755 "$mount"
    if ! mountpoint -q "$mount"; then
        chattr -i "$mount" 2>/dev/null || true
        [ -z "$(ls -A "$mount" 2>/dev/null)" ] || die "$mount is not empty; move its contents away first."
        chattr +i "$mount" 2>/dev/null || true
    fi
    local tmp
    tmp=$(mktemp /etc/fstab.hbox.XXXXXX)
    awk -v m="$mount" '!($2 == m) && $0 != "# HBOX backup disk (hbox backup disk)"' /etc/fstab > "$tmp"
    printf '# HBOX backup disk (hbox backup disk)\nUUID=%s %s %s %s 0 %s\n' "$uuid" "$mount" "$fstype" "$options" "$pass" >> "$tmp"
    chmod 644 "$tmp"
    cp -p /etc/fstab /etc/fstab.hbox-backup
    mv -f "$tmp" /etc/fstab
    systemctl daemon-reload
    mountpoint -q "$mount" || mount "$mount" || die "Could not mount $device at $mount."
}

cmd_backup_disk() {
    local want='' format=0 keep=0 password_file='' disk path state device repo mount existing=0
    while [ "$#" -gt 0 ]; do
        case $1 in
            list) disk_list; return 0 ;;
            eject) disk_eject; return 0 ;;
            --format) format=1; shift ;;
            --keep) keep=1; shift ;;
            --password-file) password_file=$2; shift 2 ;;
            --yes | -y) export HBOX_ASSUME_YES=1; shift ;;
            -*) die "Unknown option for backup disk: $1" ;;
            *) want=$1; shift ;;
        esac
    done
    require_root
    require_env
    disk_tools
    mount=$HBOX_BACKUP_MOUNT_DEFAULT

    if [ -z "$want" ]; then
        heading "Disks on this server"
        disk_list
        [ -t 0 ] || { echo; echo "Choose one with: sudo hbox backup disk /dev/sdX"; return 0; }
        echo
        read -r -p "Use which disk for backups? (number or name, Enter to cancel) " want
        [ -n "$want" ] || die "Cancelled."
    fi
    disk=$(disk_find "$want") || die "No disk '$want'. See: sudo hbox backup disk list"
    path=$(jq -r .path <<<"$disk")
    state=$(disk_state "$disk")
    disk_usable "$disk" || die "$path cannot be used for backups: $state."
    heading "$path  $(disk_human_size "$(jq -r .size <<<"$disk")")  $(jq -r .model <<<"$disk")  — $state"

    if jq -e .current <<<"$disk" >/dev/null; then
        disk_take_over
        return 0
    elif jq -e .hbox <<<"$disk" >/dev/null; then
        device=$(findmnt -no SOURCE "$mount" 2>/dev/null || true)
        [ -n "$device" ] && jq -e --arg d "$device" 'any(.filesystems[]; .path == $d)' <<<"$disk" >/dev/null ||
            device=$(jq -r '[.filesystems[] | select(.label == "HBOX-BACKUP")][0].path' <<<"$disk")
        log "This disk already holds HBOX backups; using it as it is."
    elif jq -e .empty <<<"$disk" >/dev/null || [ "$format" = 1 ]; then
        if ! jq -e .empty <<<"$disk" >/dev/null; then
            warn "Everything on $path will be erased."
        fi
        if [ "${HBOX_ASSUME_YES:-0}" = 1 ] && [ "$format" = 1 ]; then
            :
        else
            [ -t 0 ] || die "Run interactively, or confirm with: sudo hbox backup disk $path --format --yes"
            local typed
            read -r -p "Type $(basename "$path") to erase it and use it for backups: " typed
            [ "$typed" = "$(basename "$path")" ] || die "Cancelled; nothing was changed."
        fi
        device=$(disk_format "$path")
    elif [ "$keep" = 1 ]; then
        device=$(jq -r --arg ok "$HBOX_KEEP_FILESYSTEMS" \
            '[.filesystems[] | select(($ok | contains(" " + .fstype + " ")))] | if length == 1 then .[0].path else empty end' <<<"$disk")
        [ -n "$device" ] ||
            die "--keep needs exactly one ext4, xfs, btrfs or exFAT filesystem on $path. Erase it instead with --format."
        log "Keeping the files on $device; backups go to the folder hbox/ on it."
    else
        cat >&2 <<EOF
$path already has data. Choose:
    sudo hbox backup disk $path --format   erase it (asks you to confirm)
    sudo hbox backup disk $path --keep     keep its files; store backups next to them
EOF
        die "Nothing was changed."
    fi

    disk_mount "$device" "$mount"
    repo=$mount/hbox
    # Already this server's backup disk: keep its repository (e.g. restic/
    # on a disk taken over from before HBOX).
    local configured
    configured=$(env_get RESTIC_REPOSITORY "$HBOX_BACKUP_ENV" 2>/dev/null || true)
    if [[ $configured == "$mount"/* ]] && [ -f "$configured/config" ]; then
        repo=$configured
    fi
    if [ -f "$repo/config" ]; then
        existing=1
        log "Found an HBOX backup repository on the disk."
    fi
    local args=(--repo "$repo")
    [ -n "$password_file" ] && args+=(--password-file "$password_file")
    if [ "$existing" = 1 ]; then
        # This server's password opens it (same server), or the user gives
        # the one saved when the backups were created (e.g. a new server).
        if [ -z "$password_file" ] && ! { [ -f "$HBOX_RESTIC_PASSWORD_FILE" ] &&
            RESTIC_PASSWORD_FILE=$HBOX_RESTIC_PASSWORD_FILE restic -r "$repo" --no-cache cat config >/dev/null 2>&1; }; then
            [ -t 0 ] || die "Give the password of these backups with --password-file FILE."
            local password
            read -r -s -p "Password of the backups on this disk (sudo hbox backup password on the old server): " password
            echo >&2
            password_file=$(mktemp)
            # shellcheck disable=SC2064
            trap "rm -f '$password_file'" EXIT
            printf '%s\n' "$password" > "$password_file"
            RESTIC_PASSWORD_FILE=$password_file restic -r "$repo" --no-cache cat config >/dev/null 2>&1 ||
                die "That password does not open the backups on this disk."
            args+=(--password-file "$password_file")
        fi
        args+=(--existing)
    fi
    HBOX_BACKUP_MOUNT_SET=$mount backup_setup "${args[@]}"
    if [ "$existing" = 1 ]; then
        echo >&2
        log "To bring this server back from these backups: sudo hbox backup restore"
    fi
}

# The disk already holds this server's repository but was mounted outside
# HBOX: move it to HBOX's mount point, keeping the repository and its files.
disk_take_over() {
    local old device repo relative mount=$HBOX_BACKUP_MOUNT_DEFAULT tmp
    old=$(disk_current_mount)
    device=$(findmnt -no SOURCE "$old")
    repo=$(env_get RESTIC_REPOSITORY "$HBOX_BACKUP_ENV")
    relative=${repo#"$old"}
    log "This disk holds the current backups (mounted at $old); HBOX takes it over as it is."

    exec 9>/run/hbox-backup.lock
    flock -n 9 || die "A backup is running; wait for it to finish."
    if pgrep -x restic >/dev/null; then
        log "Waiting for Backups to finish its current task"
        local deadline=$((SECONDS + 600))
        while pgrep -x restic >/dev/null; do
            [ "$SECONDS" -ge "$deadline" ] && die "Backups is still busy; try again later."
            sleep 3
        done
    fi
    systemctl stop hbox-backrest.service >/dev/null 2>&1 || true
    # On failure, Backups must come back with the disk where it was.
    # shellcheck disable=SC2064
    trap "findmnt -rno TARGET '$device' >/dev/null || mount '$device' '$old' 2>/dev/null; systemctl start hbox-backrest.service >/dev/null 2>&1 || true" EXIT

    # The old mount entry would mount the disk a second time at boot.
    tmp=$(mktemp /etc/fstab.hbox.XXXXXX)
    awk -v m="$old" '$1 ~ /^#/ || $2 != m' /etc/fstab > "$tmp"
    chmod 644 "$tmp"
    cp -p /etc/fstab /etc/fstab.hbox-before-takeover
    sync
    umount "$old" || { rm -f "$tmp"; die "The backup disk is busy at $old; try again in a minute."; }
    mv -f "$tmp" /etc/fstab
    disk_mount "$device" "$mount"
    trap - EXIT
    [ -f "$mount$relative/config" ] || die "The repository is missing at $mount$relative."
    rmdir "$old" 2>/dev/null || true
    log "Moved the backup disk from $old to $mount (previous /etc/fstab: /etc/fstab.hbox-before-takeover)"
    HBOX_BACKUP_MOUNT_SET=$mount backup_setup --existing --repo "$mount$relative"
}

disk_eject() {
    require_root
    local mount
    mount=$(env_get_default HBOX_BACKUP_MOUNT '' "$HBOX_BACKUP_ENV")
    [ -n "$mount" ] || die "No backup disk is set up (sudo hbox backup disk)."
    mountpoint -q "$mount" || { log "The backup disk is not connected."; return 0; }
    exec 9>/run/hbox-backup.lock
    flock -n 9 || die "A backup is running; wait for it to finish."
    # Backrest tidies up after a backup (retention, index); let it finish,
    # then keep it from starting anything while the disk goes away.
    local deadline=$((SECONDS + 600))
    if pgrep -x restic >/dev/null; then
        log "Waiting for Backups to finish its current task"
        while pgrep -x restic >/dev/null; do
            [ "$SECONDS" -ge "$deadline" ] && die "Backups is still busy; try again later."
            sleep 3
        done
    fi
    systemctl stop hbox-backrest.service >/dev/null 2>&1 || true
    sync
    if ! umount "$mount"; then
        systemctl start hbox-backrest.service >/dev/null 2>&1 || true
        die "The backup disk is busy; try again in a minute."
    fi
    systemctl start hbox-backrest.service >/dev/null 2>&1 || true
    log "You can unplug the backup disk now. Backups wait until it is back."
}
