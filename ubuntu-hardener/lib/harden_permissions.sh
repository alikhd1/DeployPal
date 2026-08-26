#!/usr/bin/env bash
# lib/harden_permissions.sh - sensitive file, SUID and world-writable audits.
# shellcheck shell=bash

[[ -n "${UH_PERM_LOADED:-}" ]] && return 0
UH_PERM_LOADED=1

# Sensitive files: path|max_mode|owner|group|recommended_mode
UH_SENSITIVE_FILES=(
    "/etc/passwd|644|root|root|644"
    "/etc/group|644|root|root|644"
    "/etc/shadow|640|root|shadow|640"
    "/etc/gshadow|640|root|shadow|640"
    "/etc/sudoers|440|root|root|440"
    "/etc/crontab|644|root|root|600"
)

declare -ga UH_PERM_FIXES=()      # "path|current|recommended_mode|owner:group"
declare -ga UH_WW_FILES=()
declare -ga UH_WW_DIRS=()
declare -ga UH_BAD_HOMES=()

# mode_gt A B -> true if numeric mode A grants anything mode B does not.
mode_exceeds() {
    local a="$1" b="$2"
    a=$(( 8#${a: -3} )); b=$(( 8#${b: -3} ))
    (( (a & ~b & 0777) != 0 ))
}

# ---------------------------------------------------------------------------
# Audit (category files, 10 points)
# ---------------------------------------------------------------------------
audit_permissions() {
    headline "Filesystem & permissions audit"
    UH_PERM_FIXES=(); UH_WW_FILES=(); UH_WW_DIRS=(); UH_BAD_HOMES=()

    local st ev spec path maxmode owner group rec

    # FILE-001/002/003: sensitive files
    local bad_normal="" bad_secret=""
    for spec in "${UH_SENSITIVE_FILES[@]}"; do
        IFS='|' read -r path maxmode owner group rec <<<"$spec"
        [[ -e "$path" ]] || continue
        local cur curown curgrp
        cur="$(stat -c '%a' "$path")"; curown="$(stat -c '%U' "$path")"; curgrp="$(stat -c '%G' "$path")"
        if mode_exceeds "$cur" "$maxmode" || [[ "$curown" != "$owner" ]] || [[ "$curgrp" != "$group" ]]; then
            UH_PERM_FIXES+=("$path|$cur $curown:$curgrp|$rec|$owner:$group")
            case "$path" in
                /etc/shadow|/etc/gshadow|/etc/sudoers) bad_secret+="$path($cur,$curown:$curgrp) " ;;
                *) bad_normal+="$path($cur,$curown:$curgrp) " ;;
            esac
        fi
    done
    if [[ -n "$bad_normal" ]]; then st="FAIL"; ev="$bad_normal"; else st="PASS"; ev="/etc/passwd, /etc/group, /etc/crontab OK"; fi
    record_check "FILE-001" files medium 1 "$st" "passwd/group/crontab permissions" "$ev" \
        "chmod/chown to the recommended values (listed per file below)." yes
    if [[ -n "$bad_secret" ]]; then st="FAIL"; ev="$bad_secret"; else st="PASS"; ev="/etc/shadow, /etc/gshadow, /etc/sudoers OK"; fi
    record_check "FILE-002" files critical 2 "$st" "shadow/gshadow/sudoers permissions" "$ev" \
        "Restore root:shadow 640 (shadow files) / root:root 440 (sudoers)." yes

    # FILE-003 /etc/ssh private host keys
    local badkeys="" k
    for k in /etc/ssh/ssh_host_*_key; do
        [[ -e "$k" ]] || continue
        local km
        km="$(stat -c '%a' "$k")"
        if mode_exceeds "$km" "600"; then badkeys+="$k($km) "; fi
    done
    if [[ -n "$badkeys" ]]; then st="FAIL"; ev="private host keys readable by others: $badkeys"; else st="PASS"; ev="host private keys are mode 600 or stricter"; fi
    record_check "FILE-003" files medium 1 "$st" "SSH host key permissions" "$ev" "chmod 600 the flagged private keys." yes

    # FILE-004 world-writable regular files
    local scan
    scan="$(timeout "$UH_FS_SCAN_TIMEOUT" find / -xdev \
              -path /proc -prune -o -path /sys -prune -o -path /run -prune -o \
              -path /snap -prune -o -path /var/lib/docker -prune -o \
              -type f -perm -0002 -print 2>/dev/null | head -n "$UH_FS_SCAN_LIMIT" || true)"
    if [[ -n "$scan" ]]; then
        mapfile -t UH_WW_FILES <<<"$scan"
        st="FAIL"; ev="world-writable files (max $UH_FS_SCAN_LIMIT shown): $(paste -sd' ' - <<<"$scan")"
    else
        st="PASS"; ev="no world-writable regular files found on the root filesystem"
    fi
    record_check "FILE-004" files high 2 "$st" "No world-writable files" "$ev" \
        "chmod o-w each file after confirming no application depends on it (offered per file)." no

    # FILE-005 world-writable dirs without sticky bit
    scan="$(timeout "$UH_FS_SCAN_TIMEOUT" find / -xdev \
              -path /proc -prune -o -path /sys -prune -o -path /run -prune -o \
              -path /snap -prune -o -path /var/lib/docker -prune -o \
              -type d -perm -0002 ! -perm -1000 -print 2>/dev/null | head -n "$UH_FS_SCAN_LIMIT" || true)"
    if [[ -n "$scan" ]]; then
        mapfile -t UH_WW_DIRS <<<"$scan"
        st="FAIL"; ev="world-writable dirs missing sticky bit: $(paste -sd' ' - <<<"$scan")"
    else
        st="PASS"; ev="all world-writable directories carry the sticky bit"
    fi
    record_check "FILE-005" files medium 1 "$st" "World-writable directories have the sticky bit" "$ev" \
        "chmod +t on flagged directories (offered per directory)." no

    # FILE-006 SUID/SGID inventory vs common baseline
    local suid_known="ping mount umount su sudo sudoedit passwd chsh chfn chage gpasswd newgrp expiry fusermount fusermount3 pkexec polkit-agent-helper-1 dbus-daemon-launch-helper ssh-keysign chrome-sandbox snap-confine ubuntu-core-launcher mail-lock mail-unlock mail-touchlock dotlockfile ssh-agent utempter pppd crontab wall write write.ul unix_chkpwd mount.nfs bwrap"
    scan="$(timeout "$UH_FS_SCAN_TIMEOUT" find / -xdev \
              -path /proc -prune -o -path /snap -prune -o -path /var/lib/docker -prune -o \
              -type f \( -perm -4000 -o -perm -2000 \) -print 2>/dev/null || true)"
    local unusual="" b
    while IFS= read -r b; do
        [[ -n "$b" ]] || continue
        local base="${b##*/}"
        if [[ " $suid_known " != *" $base "* ]]; then unusual+="$b "; fi
    done <<<"$scan"
    if [[ -n "$unusual" ]]; then
        st="FAIL"; ev="SUID/SGID binaries outside the common baseline: $(truncate_text "$unusual" 400)"
    elif [[ -z "$scan" ]]; then
        st="UNKNOWN"; ev="scan produced no results (timeout?)"
    else
        st="PASS"; ev="only well-known SUID/SGID binaries found"
    fi
    record_check "FILE-006" files medium 1 "$st" "No unexpected SUID/SGID binaries" "$ev" \
        "Verify each flagged binary belongs to an installed package (dpkg -S <path>); remove the bit only after manual review - not automated." no

    # FILE-007 home directory permissions
    local baddirs="" user home
    while IFS=: read -r user _ uid _ _ home _; do
        (( uid >= 1000 && uid < 65534 )) || continue
        [[ -d "$home" ]] || continue
        local hm
        hm="$(stat -c '%a' "$home")"
        if [[ "$hm" =~ [2367]$ ]] || [[ "$hm" =~ ^7[0-7][67]$ ]]; then
            baddirs+="$home($hm) "
        elif mode_exceeds "$hm" "755"; then
            baddirs+="$home($hm) "
        fi
        [[ "$hm" =~ [2367]$ ]] && UH_BAD_HOMES+=("$home|$hm")
    done < /etc/passwd
    # Only world-writable homes are queued for fixes; merely-readable homes are reported.
    if [[ -n "$baddirs" ]]; then st="FAIL"; ev="review: $baddirs (750 recommended)"; else st="PASS"; ev="home directories are not world-writable"; fi
    record_check "FILE-007" files medium 1 "$st" "Home directory permissions" "$ev" \
        "chmod 750 \$HOME (offered for world-writable homes; others: manual, may affect web servers serving ~user)." no

    # FILE-008 /tmp, /var/tmp, /dev/shm mount options
    local badmnt="" notes="" m opts
    for m in /tmp /var/tmp /dev/shm; do
        opts="$(findmnt -no OPTIONS --target "$m" 2>/dev/null | head -1 || true)"
        [[ -n "$opts" ]] || continue
        local src
        src="$(findmnt -no TARGET --target "$m" 2>/dev/null | head -1 || true)"
        # Not a separate mount (Ubuntu default for /tmp): informational only.
        [[ "$src" == "$m" ]] || { notes+="$m=on-rootfs "; continue; }
        local missing=""
        [[ ",$opts," == *,nodev,* ]]  || missing+="nodev,"
        [[ ",$opts," == *,nosuid,* ]] || missing+="nosuid,"
        [[ -n "$missing" ]] && badmnt+="$m(missing ${missing%,}) "
    done
    if [[ -n "$badmnt" ]]; then st="FAIL"; ev="$badmnt${notes:+ | $notes}"; else st="PASS"; ev="separate temp mounts carry nodev,nosuid${notes:+ | $notes}"; fi
    record_check "FILE-008" files low 1 "$st" "Hardened mount options for /tmp, /var/tmp, /dev/shm" "$ev" \
        "Add nodev,nosuid (and noexec where compatible) in /etc/fstab or systemd mount units. Manual: wrong fstab edits can break boot." no
}

# ---------------------------------------------------------------------------
# Remediation plan
# ---------------------------------------------------------------------------
plan_permissions() {
    if (( ${#UH_PERM_FIXES[@]} > 0 )) || check_failed FILE-003; then
        plan_add "sensitive-perms" safe \
            "Fix permissions on sensitive system files" \
            "Loose permissions on passwd/shadow/sudoers/SSH keys expose credentials and policy to local users." \
            "chmod/chown each flagged file to its recommended value (every file is listed before you confirm)." \
            "Very low. These are the distribution's own defaults." \
            "Restored automatically by --rollback <backup-id> (perm-change entries)." \
            apply_sensitive_perms "FILE-001 FILE-002 FILE-003"
    fi
    if (( ${#UH_WW_FILES[@]} > 0 )) || (( ${#UH_WW_DIRS[@]} > 0 )); then
        plan_add "world-writable" review \
            "Remove world-write access / add sticky bit (per path)" \
            "World-writable paths allow any local user to tamper with data or plant files." \
            "chmod o-w per flagged file; chmod +t per flagged directory - each confirmed individually." \
            "Medium: an application that relies on world-writability would break - confirm per path." \
            "Restored automatically by --rollback <backup-id>." \
            apply_world_writable "FILE-004 FILE-005"
    fi
    if (( ${#UH_BAD_HOMES[@]} > 0 )); then
        plan_add "home-perms" review \
            "Restrict world-writable home directories to 750" \
            "A world-writable home lets any user plant startup files (.bashrc) for that account." \
            "chmod 750 on each flagged home directory, confirmed individually." \
            "Low-medium: breaks setups where other users write into the home directory." \
            "Restored automatically by --rollback <backup-id>." \
            apply_home_perms "FILE-007"
    fi
}

apply_sensitive_perms() {
    local fix path cur rec own
    for fix in "${UH_PERM_FIXES[@]}"; do
        IFS='|' read -r path cur rec own <<<"$fix"
        info "  $path: current [$cur] -> recommended [mode $rec, $own]"
        set_perms "$path" "$rec" "$own" || return 1
    done
    local k
    for k in /etc/ssh/ssh_host_*_key; do
        [[ -e "$k" ]] || continue
        if mode_exceeds "$(stat -c '%a' "$k")" "600"; then
            set_perms "$k" 600 root:root || return 1
        fi
    done
    return 0
}

apply_world_writable() {
    local p applied=0
    for p in "${UH_WW_FILES[@]}"; do
        [[ -f "$p" ]] || continue
        if confirm "Remove world-write from FILE $p ($(stat -c '%a %U:%G' "$p"))?"; then
            set_perms "$p" "o-w" || return 1
            applied=$((applied + 1))
        fi
    done
    for p in "${UH_WW_DIRS[@]}"; do
        [[ -d "$p" ]] || continue
        if confirm "Add sticky bit to DIRECTORY $p ($(stat -c '%a %U:%G' "$p"))?"; then
            set_perms "$p" "+t" || return 1
            applied=$((applied + 1))
        fi
    done
    (( applied > 0 )) || return 2
    return 0
}

apply_home_perms() {
    local entry home mode applied=0
    for entry in "${UH_BAD_HOMES[@]}"; do
        IFS='|' read -r home mode <<<"$entry"
        if confirm "chmod 750 $home (currently $mode)?"; then
            set_perms "$home" 750 || return 1
            applied=$((applied + 1))
        fi
    done
    (( applied > 0 )) || return 2
    return 0
}
