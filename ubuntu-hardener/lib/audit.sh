#!/usr/bin/env bash
# lib/audit.sh - check engine (rule registry), remediation-plan registry,
# baseline/host audit and logging & auditing checks.
# shellcheck shell=bash

[[ -n "${UH_AUDIT_LOADED:-}" ]] && return 0
UH_AUDIT_LOADED=1

# ---------------------------------------------------------------------------
# Check registry.
# Every rule has: ID, category, severity, weight, status, title, evidence,
# remediation, and whether it is safe to automate. Weight 0 = informational
# (not scored). Statuses: PASS FAIL UNKNOWN INFO.
# ---------------------------------------------------------------------------
declare -ga UH_CHECK_IDS=()
declare -gA UH_CHECK_CATEGORY=() UH_CHECK_SEVERITY=() UH_CHECK_WEIGHT=()
declare -gA UH_CHECK_STATUS=() UH_CHECK_TITLE=() UH_CHECK_EVIDENCE=()
declare -gA UH_CHECK_REMEDIATION=() UH_CHECK_AUTO=()

# Category score budget (total 100). "baseline" is informational only.
declare -gA UH_CATEGORY_POINTS=(
    [ssh]=15 [firewall]=20 [auth]=15 [services]=15
    [files]=10 [kernel]=10 [updates]=10 [logging]=5 [baseline]=0
)
declare -ga UH_CATEGORY_ORDER=(ssh firewall auth services files kernel updates logging baseline)

# record_check ID CATEGORY SEVERITY WEIGHT STATUS TITLE EVIDENCE REMEDIATION AUTO
record_check() {
    local id="$1"
    UH_CHECK_IDS+=("$id")
    UH_CHECK_CATEGORY[$id]="$2"
    UH_CHECK_SEVERITY[$id]="$3"
    UH_CHECK_WEIGHT[$id]="$4"
    UH_CHECK_STATUS[$id]="$5"
    UH_CHECK_TITLE[$id]="$6"
    UH_CHECK_EVIDENCE[$id]="$7"
    UH_CHECK_REMEDIATION[$id]="$8"
    UH_CHECK_AUTO[$id]="${9:-no}"
    log CHECK "$id [$2/$3/w=$4] $5 :: $6"
}

check_status() { printf '%s' "${UH_CHECK_STATUS[$1]:-UNKNOWN}"; }
check_failed() { [[ "${UH_CHECK_STATUS[$1]:-}" == "FAIL" ]]; }

reset_checks() {
    UH_CHECK_IDS=()
    UH_CHECK_CATEGORY=(); UH_CHECK_SEVERITY=(); UH_CHECK_WEIGHT=()
    UH_CHECK_STATUS=(); UH_CHECK_TITLE=(); UH_CHECK_EVIDENCE=()
    UH_CHECK_REMEDIATION=(); UH_CHECK_AUTO=()
}

# ---------------------------------------------------------------------------
# Remediation plan registry.
# Groups: safe   - safe automatic improvements
#         review - requires administrator review (installs, account changes)
#         risky  - may affect connectivity or application behaviour
# ---------------------------------------------------------------------------
declare -ga UH_PLAN_IDS=()
declare -gA UH_PLAN_GROUP=() UH_PLAN_TITLE=() UH_PLAN_WHY=() UH_PLAN_CHANGES=()
declare -gA UH_PLAN_RISK=() UH_PLAN_ROLLBACK=() UH_PLAN_FUNC=() UH_PLAN_CHECKS=()

# plan_add ID GROUP TITLE WHY CHANGES RISK ROLLBACK FUNC CHECK_IDS
plan_add() {
    local id="$1"
    UH_PLAN_IDS+=("$id")
    UH_PLAN_GROUP[$id]="$2"
    UH_PLAN_TITLE[$id]="$3"
    UH_PLAN_WHY[$id]="$4"
    UH_PLAN_CHANGES[$id]="$5"
    UH_PLAN_RISK[$id]="$6"
    UH_PLAN_ROLLBACK[$id]="$7"
    UH_PLAN_FUNC[$id]="$8"
    UH_PLAN_CHECKS[$id]="$9"
}

plan_count_group() {
    local group="$1" id n=0
    for id in "${UH_PLAN_IDS[@]}"; do
        [[ "${UH_PLAN_GROUP[$id]}" == "$group" ]] && n=$((n + 1))
    done
    printf '%s' "$n"
}

# ---------------------------------------------------------------------------
# Host information (printed and embedded in reports, not scored).
# ---------------------------------------------------------------------------
HOST_NAME="" HOST_KERNEL="" HOST_IPS="" HOST_UPTIME="" HOST_USERS=""

collect_host_info() {
    HOST_NAME="$(hostname 2>/dev/null || echo unknown)"
    HOST_KERNEL="$(uname -r 2>/dev/null || echo unknown)"
    HOST_IPS="$(hostname -I 2>/dev/null | tr -s ' ' | sed 's/ $//' || true)"
    [[ -z "$HOST_IPS" ]] && HOST_IPS="unknown"
    HOST_UPTIME="$(uptime -p 2>/dev/null || echo unknown)"
    HOST_USERS="$(who 2>/dev/null | awk '{print $1}' | sort -u | paste -sd, - || true)"
    [[ -z "$HOST_USERS" ]] && HOST_USERS="none"
}

env_description() {
    local d=""
    if (( IS_CONTAINER )); then
        d="container ($VIRT_TYPE)"
    elif [[ "$VIRT_TYPE" != "none" && "$VIRT_TYPE" != "unknown" ]]; then
        d="virtual machine ($VIRT_TYPE)"
    else
        d="bare metal or undetected hypervisor"
    fi
    [[ "$CLOUD_HINT" != "none" ]] && d="$d, cloud: $CLOUD_HINT"
    if (( IS_DESKTOP )); then d="$d, desktop"; else d="$d, server"; fi
    printf '%s' "$d"
}

# ---------------------------------------------------------------------------
# Baseline audit (informational)
# ---------------------------------------------------------------------------
audit_baseline() {
    headline "Baseline audit"
    collect_host_info

    info "Host: $HOST_NAME | $OS_PRETTY | kernel $HOST_KERNEL"
    info "IPs: $HOST_IPS | uptime: $HOST_UPTIME | logged-in users: $HOST_USERS"
    info "Environment: $(env_description)"

    local st="INFO" ev
    if (( IS_SUPPORTED_UBUNTU )); then
        ev="$OS_PRETTY (supported release)"
    else
        st="FAIL"
        ev="$OS_PRETTY (untested by this tool)"
    fi
    record_check "BASE-001" baseline info 0 "$st" "Operating system release" "$ev" \
        "Use an Ubuntu LTS release with active security support." no

    record_check "BASE-002" baseline info 0 INFO "Runtime environment" "$(env_description)" \
        "Container/cloud environments: host- or provider-level controls also apply." no

    # Secure boot
    local sb="UNKNOWN" sbe="cannot determine"
    if [[ ! -d /sys/firmware/efi ]]; then
        sb="INFO"; sbe="Legacy BIOS boot (Secure Boot not applicable)"
    elif have mokutil; then
        local out
        out="$(mokutil --sb-state 2>/dev/null || true)"
        if grep -qi "enabled" <<<"$out"; then sb="PASS"; sbe="SecureBoot enabled"
        elif grep -qi "disabled" <<<"$out"; then sb="FAIL"; sbe="SecureBoot disabled"
        fi
    fi
    record_check "BASE-003" baseline low 0 "$sb" "UEFI Secure Boot" "$sbe" \
        "Enable Secure Boot in firmware settings where practical." no

    # Installed security tooling overview
    local tools="" t
    for t in ufw fail2ban auditd lynis rkhunter clamav apparmor-utils unattended-upgrades; do
        if pkg_installed "$t"; then tools+="$t:yes "; else tools+="$t:no "; fi
    done
    record_check "BASE-004" baseline info 0 INFO "Installed security tooling" "$tools" \
        "Consider ufw, fail2ban, auditd and unattended-upgrades (offered below)." no
}

# ---------------------------------------------------------------------------
# Logging & auditing (scored, 5 points)
# ---------------------------------------------------------------------------
audit_logging() {
    headline "Logging & auditing audit"

    # LOG-001 journald persistence
    local st ev storage="auto"
    if (( ! HAVE_SYSTEMD )); then
        st="UNKNOWN"; ev="systemd not running (container?)"
    else
        storage="$(grep -rhsE '^\s*Storage=' /etc/systemd/journald.conf /etc/systemd/journald.conf.d/ 2>/dev/null | tail -1 | cut -d= -f2 | tr -d ' ' || true)"
        [[ -z "$storage" ]] && storage="auto(default)"
        if [[ -d /var/log/journal ]] || [[ "$storage" == "persistent" ]]; then
            st="PASS"; ev="journald storage: $storage; /var/log/journal exists: $([[ -d /var/log/journal ]] && echo yes || echo no)"
        else
            st="FAIL"; ev="journald storage: $storage; /var/log/journal missing - logs are lost at reboot"
        fi
    fi
    record_check "LOG-001" logging medium 2 "$st" "Persistent systemd journal" "$ev" \
        "Create /var/log/journal and set Storage=persistent via a journald drop-in." yes

    # LOG-002 auditd
    if pkg_installed auditd; then
        if unit_active auditd; then
            st="PASS"; ev="auditd installed and active"
        else
            st="FAIL"; ev="auditd installed but not active"
        fi
    else
        st="FAIL"; ev="auditd not installed"
    fi
    record_check "LOG-002" logging medium 2 "$st" "Kernel audit daemon (auditd)" "$ev" \
        "Install and enable auditd to record security-relevant syscalls and changes." no

    # LOG-003 log file permissions
    local bad="" f
    for f in /var/log/auth.log /var/log/syslog /var/log/kern.log /var/log/wtmp /var/log/btmp /var/log/lastlog; do
        [[ -e "$f" ]] || continue
        local mode
        mode="$(stat -c '%a' "$f" 2>/dev/null || echo '')"
        # Flag world-readable btmp and any world-writable log.
        if [[ "$f" == "/var/log/btmp" && "$mode" =~ [4567]$ ]]; then
            bad+="$f($mode) "
        elif [[ "$mode" =~ [2367]$ ]]; then
            bad+="$f($mode) "
        fi
    done
    if [[ -n "$bad" ]]; then
        st="FAIL"; ev="over-permissive: $bad"
    else
        st="PASS"; ev="checked auth.log/syslog/kern.log/wtmp/btmp/lastlog"
    fi
    record_check "LOG-003" logging low 1 "$st" "Log file permissions" "$ev" \
        "Remove world access from sensitive logs (e.g. chmod o-rwx /var/log/btmp)." yes
}

plan_logging() {
    if check_failed "LOG-001"; then
        plan_add "journald-persist" safe \
            "Enable persistent systemd journal" \
            "Without persistent storage, all journal logs are lost on reboot, destroying forensic evidence." \
            "Create /var/log/journal; write $UH_JOURNALD_DROPIN with Storage=persistent, SystemMaxUse=$UH_JOURNAL_MAX_USE; restart systemd-journald." \
            "Very low. Journald restart is transparent; disk usage capped at $UH_JOURNAL_MAX_USE." \
            "sudo $UH_SELF_NAME --rollback <backup-id> (removes the drop-in)" \
            apply_journald_persistence "LOG-001"
    fi
    if check_failed "LOG-003"; then
        plan_add "log-perms" safe \
            "Tighten permissions on sensitive log files" \
            "World-readable/writable logs leak login records and allow tampering." \
            "chmod o-rwx on the flagged files under /var/log." \
            "Very low. Services write logs as root/syslog and are unaffected." \
            "Restored automatically by --rollback <backup-id> (perm-change entries)." \
            apply_log_perms "LOG-003"
    fi
    if check_failed "LOG-002"; then
        plan_add "install-auditd" review \
            "Install and enable auditd" \
            "auditd records security-relevant events (auth changes, privilege use) for investigation and compliance." \
            "apt-get install auditd; systemctl enable --now auditd." \
            "Low. Small I/O overhead; log volume grows under /var/log/audit." \
            "sudo apt-get remove auditd (package installs are not auto-removed by rollback)" \
            apply_install_auditd "LOG-002"
    fi
}

apply_journald_persistence() {
    write_managed_file "$UH_JOURNALD_DROPIN" \
"# Managed by $UH_NAME - persistent journal
[Journal]
Storage=persistent
SystemMaxUse=$UH_JOURNAL_MAX_USE" 0644 || return 1
    run_cmd "create /var/log/journal" mkdir -p /var/log/journal || return 1
    if unit_exists systemd-journald.service; then
        run_cmd "apply journal ACLs" systemd-tmpfiles --create --prefix /var/log/journal || true
        run_cmd "restart systemd-journald" systemctl restart systemd-journald || return 1
    fi
    return 0
}

apply_log_perms() {
    local f
    for f in /var/log/auth.log /var/log/syslog /var/log/kern.log /var/log/btmp; do
        [[ -e "$f" ]] || continue
        local mode
        mode="$(stat -c '%a' "$f" 2>/dev/null || echo '')"
        if [[ "$f" == "/var/log/btmp" && "$mode" =~ [1-7]$ ]] || [[ "$mode" =~ [2367]$ ]]; then
            set_perms "$f" "o-rwx" || return 1
        fi
    done
    return 0
}

apply_install_auditd() {
    apt_install auditd || return 1
    if unit_exists auditd.service; then
        run_cmd "enable auditd" systemctl enable --now auditd || return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Full audit orchestrator
# ---------------------------------------------------------------------------
run_full_audit() {
    audit_baseline
    audit_ssh
    audit_firewall
    audit_auth
    audit_services
    audit_permissions
    audit_kernel
    audit_updates
    audit_logging
}

build_plan() {
    UH_PLAN_IDS=()
    UH_PLAN_GROUP=(); UH_PLAN_TITLE=(); UH_PLAN_WHY=(); UH_PLAN_CHANGES=()
    UH_PLAN_RISK=(); UH_PLAN_ROLLBACK=(); UH_PLAN_FUNC=(); UH_PLAN_CHECKS=()
    plan_ssh
    plan_firewall
    plan_auth
    plan_services
    plan_permissions
    plan_kernel
    plan_updates
    plan_logging
}
