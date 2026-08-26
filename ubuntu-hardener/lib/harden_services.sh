#!/usr/bin/env bash
# lib/harden_services.sh - systemd services, cron/at/timers and persistence.
# shellcheck shell=bash

[[ -n "${UH_SVC_LOADED:-}" ]] && return 0
UH_SVC_LOADED=1

# Legacy / risky network daemons worth flagging (package -> unit).
UH_RISKY_SERVICES=(
    "telnetd|inetd.service"
    "openbsd-inetd|inetd.service"
    "xinetd|xinetd.service"
    "rsh-server|rsh.socket"
    "nis|ypserv.service"
    "tftpd-hpa|tftpd-hpa.service"
    "rpcbind|rpcbind.service"
    "talkd|ntalk.service"
)
# Desktop-oriented services that rarely belong on a server.
UH_SERVER_UNWANTED=(
    "avahi-daemon|avahi-daemon.service"
    "cups|cups.service"
    "cups-browsed|cups-browsed.service"
)

declare -ga UH_RISKY_FOUND=()      # "pkg|unit|state"
declare -ga UH_WW_UNIT_FILES=()

# ---------------------------------------------------------------------------
# Audit (category services, 15 points)
# ---------------------------------------------------------------------------
audit_services() {
    headline "Services & scheduled tasks audit"
    UH_RISKY_FOUND=(); UH_WW_UNIT_FILES=()

    local st ev

    if (( ! HAVE_SYSTEMD )); then
        record_check "SVC-001" services high 5 UNKNOWN "No legacy/risky network services" \
            "systemd not running (container?) - service checks limited" \
            "Audit the container image / host instead." no
    else
        # SVC-001 risky legacy services
        local found="" spec pkg unit
        for spec in "${UH_RISKY_SERVICES[@]}"; do
            IFS='|' read -r pkg unit <<<"$spec"
            if pkg_installed "$pkg"; then
                local state="installed"
                unit_active "$unit" && state="ACTIVE"
                UH_RISKY_FOUND+=("$pkg|$unit|$state")
                found+="$pkg($state) "
            fi
        done
        if [[ -n "$found" ]]; then st="FAIL"; ev="legacy/insecure services present: $found"; else st="PASS"; ev="none of: telnet, inetd/xinetd, rsh, NIS, tftp, rpcbind, talk"; fi
        record_check "SVC-001" services high 5 "$st" "No legacy/risky network services" "$ev" \
            "Stop and disable (offered per service), then remove the package manually once confirmed unused." no

        # SVC-002 failed units
        local failed
        failed="$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | paste -sd' ' - || true)"
        if [[ -n "$failed" ]]; then st="FAIL"; ev="failed units: $failed"; else st="PASS"; ev="no failed systemd units"; fi
        record_check "SVC-002" services low 1 "$st" "No failed systemd units" "$ev" \
            "Investigate with 'systemctl status <unit>' and 'journalctl -u <unit>' - not automated." no

        # SVC-006 desktop services on a server
        if (( ! IS_DESKTOP )); then
            local unwanted=""
            for spec in "${UH_SERVER_UNWANTED[@]}"; do
                IFS='|' read -r pkg unit <<<"$spec"
                if unit_active "$unit"; then
                    UH_RISKY_FOUND+=("$pkg|$unit|ACTIVE")
                    unwanted+="$unit "
                fi
            done
            if [[ -n "$unwanted" ]]; then st="FAIL"; ev="desktop-oriented services active on a server: $unwanted"; else st="PASS"; ev="no avahi/cups on this server"; fi
            record_check "SVC-006" services medium 2 "$st" "No desktop services on a server" "$ev" \
                "Disable avahi-daemon/cups unless actually used (offered per service)." no
        fi

        # SVC-007 enabled services inventory (informational)
        local n_enabled
        n_enabled="$(systemctl list-unit-files --type=service --state=enabled --no-legend 2>/dev/null | wc -l | tr -d ' ' || true)"
        local n_running
        n_running="$(systemctl list-units --type=service --state=running --no-legend --plain 2>/dev/null | wc -l | tr -d ' ' || true)"
        record_check "SVC-007" services info 0 INFO "Service inventory" \
            "enabled services: $n_enabled, running: $n_running (full list in the run log)" \
            "Disable services you do not need; every running service is attack surface." no
        systemctl list-units --type=service --state=running --no-legend --plain 2>/dev/null >> "${UH_LOG_FILE:-/dev/null}" || true
    fi

    # SVC-003 world-writable unit/cron files
    local scan
    scan="$(timeout "$UH_FS_SCAN_TIMEOUT" find \
              /etc/systemd/system /lib/systemd/system /usr/lib/systemd/system \
              /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.weekly /etc/cron.monthly \
              /etc/init.d /var/spool/cron \
              -type f -perm -0002 -print 2>/dev/null | head -n "$UH_FS_SCAN_LIMIT" || true)"
    if [[ -n "$scan" ]]; then
        mapfile -t UH_WW_UNIT_FILES <<<"$scan"
        st="FAIL"; ev="world-writable service/cron files: $(paste -sd' ' - <<<"$scan")"
    else
        st="PASS"; ev="no world-writable unit or cron files"
    fi
    record_check "SVC-003" services high 3 "$st" "Service and cron files are not world-writable" "$ev" \
        "chmod o-w each flagged file (root-run code must not be editable by everyone)." yes

    # SVC-004 cron file/directory permissions
    local badcron="" c
    for c in /etc/crontab /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.weekly /etc/cron.monthly; do
        [[ -e "$c" ]] || continue
        local cm cown
        cm="$(stat -c '%a' "$c")"; cown="$(stat -c '%U' "$c")"
        if [[ "$cown" != "root" ]] || [[ "$cm" =~ [2367]$ ]] || [[ "$cm" =~ [2367].$ ]]; then
            badcron+="$c($cown,$cm) "
        fi
    done
    if [[ -n "$badcron" ]]; then st="FAIL"; ev="$badcron"; else st="PASS"; ev="cron files root-owned, not group/world-writable"; fi
    record_check "SVC-004" services medium 2 "$st" "Cron configuration permissions" "$ev" \
        "chown root and remove group/world write on the flagged entries." yes

    # SVC-005 scheduled-task inventory (informational)
    local crontabs timers atq_n=0
    crontabs="$(ls /var/spool/cron/crontabs 2>/dev/null | paste -sd, - || true)"
    timers="$(systemctl list-timers --no-legend --plain 2>/dev/null | awk '{print $NF}' | grep -v '^$' | sort -u | head -15 | paste -sd, - || true)"
    if have atq; then
        atq_n="$(atq 2>/dev/null | wc -l | tr -d ' ' || true)"
    fi
    record_check "SVC-005" services info 0 INFO "Scheduled tasks inventory" \
        "user crontabs: ${crontabs:-none}; at jobs: ${atq_n:-0}; timers: $(truncate_text "${timers:-none}" 250)" \
        "Review each scheduled task; attackers use cron/timers for persistence." no
}

# ---------------------------------------------------------------------------
# Remediation plan
# ---------------------------------------------------------------------------
plan_services() {
    if check_failed SVC-003 || check_failed SVC-004; then
        plan_add "cron-unit-perms" safe \
            "Fix permissions on cron and systemd unit files" \
            "World-writable root-executed files are a trivial local privilege escalation." \
            "chmod o-w (and chown root where needed) on the flagged unit/cron paths." \
            "Very low." \
            "Restored automatically by --rollback <backup-id>." \
            apply_cron_unit_perms "SVC-003 SVC-004"
    fi
    if (( ${#UH_RISKY_FOUND[@]} > 0 )); then
        plan_add "disable-services" review \
            "Stop and disable risky/unneeded services (per service)" \
            "Legacy cleartext daemons (telnet/rsh/tftp) and unneeded listeners expand the attack surface." \
            "For each flagged service, its description and listening ports are shown; on confirmation: systemctl disable --now <unit>. Packages are NOT removed." \
            "Medium: disabling a service something depends on breaks that function (reversible: systemctl enable --now <unit>)." \
            "sudo systemctl enable --now <unit>  (also recorded in the rollback manifest)" \
            apply_disable_services "SVC-001 SVC-006"
    fi
}

apply_cron_unit_perms() {
    local f
    for f in "${UH_WW_UNIT_FILES[@]}"; do
        [[ -e "$f" ]] || continue
        set_perms "$f" "o-w" || return 1
    done
    for f in /etc/crontab /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.weekly /etc/cron.monthly; do
        [[ -e "$f" ]] || continue
        local cm cown
        cm="$(stat -c '%a' "$f")"; cown="$(stat -c '%U' "$f")"
        if [[ "$cown" != "root" ]]; then
            set_perms "$f" "g-w,o-w" root:root || return 1
        elif [[ "$cm" =~ [2367]$ ]] || [[ "$cm" =~ [2367].$ ]]; then
            set_perms "$f" "g-w,o-w" || return 1
        fi
    done
    return 0
}

svc_describe() {
    local unit="$1"
    local desc ports=""
    desc="$(systemctl show -p Description --value "$unit" 2>/dev/null || echo '?')"
    if [[ -n "$LISTEN_TABLE" ]]; then
        local proc="${unit%%.*}"
        ports="$(awk -v p="$proc" 'index($0, "\"" p "\"")>0 {print $1":"$5}' <<<"$LISTEN_TABLE" | paste -sd' ' - || true)"
    fi
    info "  Unit: $unit"
    info "  Description: $desc"
    info "  Listening: ${ports:-none/unknown}"
    info "  Impact: whatever this service provides stops immediately; reversible with 'systemctl enable --now $unit'."
}

apply_disable_services() {
    local entry pkg unit state applied=0
    local -A seen=()
    for entry in "${UH_RISKY_FOUND[@]}"; do
        IFS='|' read -r pkg unit state <<<"$entry"
        [[ -n "${seen[$unit]:-}" ]] && continue
        seen[$unit]=1
        unit_exists "$unit" || { debug "unit $unit not present, skipping"; continue; }
        echo
        svc_describe "$unit"
        if confirm "Stop and disable '$unit' (package: $pkg, state: $state)?"; then
            local was_enabled="no" was_active="no"
            unit_enabled "$unit" && was_enabled="yes"
            unit_active "$unit" && was_active="yes"
            manifest_add "service-state" "$unit" "-" "enabled=$was_enabled active=$was_active"
            run_cmd "disable $unit" systemctl disable --now "$unit" || return 1
            applied=$((applied + 1))
        fi
    done
    (( applied > 0 )) || return 2
    return 0
}
