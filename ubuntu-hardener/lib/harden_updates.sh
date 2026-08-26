#!/usr/bin/env bash
# lib/harden_updates.sh - updates, packages, AppArmor, time sync.
# shellcheck shell=bash

[[ -n "${UH_UPD_LOADED:-}" ]] && return 0
UH_UPD_LOADED=1

# ---------------------------------------------------------------------------
# Audit (category updates, 10 points)
# ---------------------------------------------------------------------------
audit_updates() {
    headline "Updates & security tooling audit"

    local st ev

    # UPD-001 pending security updates
    local pending="?" sec="?"
    if have apt-get; then
        local sim
        sim="$(apt-get -s dist-upgrade 2>/dev/null | grep '^Inst' || true)"
        pending="$(grep -c . <<<"$sim" || true)"
        [[ -n "$sim" ]] || pending=0
        sec="$(grep -ci 'security' <<<"$sim" || true)"
        [[ -n "$sim" ]] || sec=0
    fi
    if [[ "$sec" =~ ^[0-9]+$ ]] && (( sec > 0 )); then
        st="FAIL"; ev="$sec security update(s) pending ($pending upgrades total)"
    elif [[ "$pending" == "?" ]]; then
        st="UNKNOWN"; ev="could not simulate an upgrade (no apt lists? run apt-get update)"
    else
        st="PASS"; ev="no pending security updates ($pending non-security upgrades pending)"
    fi
    record_check "UPD-001" updates high 3 "$st" "No pending security updates" "$ev" \
        "Run: apt-get update && apt-get upgrade. Review held-back packages. Not automated: upgrades can restart services." no

    # UPD-002 unattended security upgrades
    local uu_pkg="no" uu_on="0"
    pkg_installed unattended-upgrades && uu_pkg="yes"
    if have apt-config; then
        uu_on="$(apt-config dump APT::Periodic::Unattended-Upgrade 2>/dev/null | grep -o '"[0-9]*"' | tr -d '"' || true)"
    fi
    if [[ "$uu_pkg" == "yes" && "$uu_on" == "1" ]]; then
        st="PASS"; ev="unattended-upgrades installed and enabled (APT::Periodic::Unattended-Upgrade=1)"
    else
        st="FAIL"; ev="installed=$uu_pkg enabled=${uu_on:-0}"
    fi
    record_check "UPD-002" updates high 3 "$st" "Automatic security updates" "$ev" \
        "Install unattended-upgrades and enable it via $UH_APT_AUTO_FILE." no

    # UPD-003 AppArmor
    local aa_enabled="unknown" profiles="?"
    if [[ -r /sys/module/apparmor/parameters/enabled ]]; then
        aa_enabled="$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null || echo unknown)"
    fi
    if [[ -r /sys/kernel/security/apparmor/profiles ]]; then
        profiles="$(wc -l < /sys/kernel/security/apparmor/profiles 2>/dev/null | tr -d ' ' || echo '?')"
    fi
    if [[ "$aa_enabled" == "Y" ]] && [[ "$profiles" =~ ^[0-9]+$ ]] && (( profiles > 0 )); then
        st="PASS"; ev="AppArmor enabled, $profiles profiles loaded"
    elif (( IS_CONTAINER )); then
        st="UNKNOWN"; ev="container environment (AppArmor is managed by the host)"
    elif [[ "$aa_enabled" == "Y" ]]; then
        st="FAIL"; ev="AppArmor enabled but no profiles loaded"
    else
        st="FAIL"; ev="AppArmor not enabled (enabled=$aa_enabled)"
    fi
    record_check "UPD-003" updates medium 2 "$st" "AppArmor mandatory access control" "$ev" \
        "Ensure apparmor is installed and enabled (kernel cmdline 'apparmor=1 security=apparmor' if disabled). Manual: requires grub changes + reboot." no

    # UPD-004 time synchronisation
    local ntp="unknown"
    if (( HAVE_SYSTEMD )) && have timedatectl; then
        ntp="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo unknown)"
    fi
    if pkg_installed chrony && unit_active chrony; then
        st="PASS"; ev="chrony active"
    elif [[ "$ntp" == "yes" ]]; then
        st="PASS"; ev="clock synchronised (systemd-timesyncd/NTP)"
    elif [[ "$ntp" == "no" ]]; then
        st="FAIL"; ev="clock NOT synchronised (NTPSynchronized=no)"
    else
        st="UNKNOWN"; ev="cannot query time sync state (container?)"
    fi
    record_check "UPD-004" updates low 1 "$st" "Time synchronisation active" "$ev" \
        "Enable NTP: timedatectl set-ntp true (accurate time matters for logs, TLS and auth)." yes

    # UPD-005 autoremovable/obsolete packages (informational)
    local autorm="?"
    if have apt-get; then
        autorm="$(apt-get -s autoremove 2>/dev/null | grep -c '^Remv' || true)"
        [[ "$autorm" =~ ^[0-9]+$ ]] || autorm=0
    fi
    record_check "UPD-005" updates info 0 INFO "Removable/obsolete packages" \
        "$autorm package(s) would be removed by 'apt-get autoremove'" \
        "Fewer installed packages = smaller attack surface. Review 'apt-get autoremove' output manually." no
}

# ---------------------------------------------------------------------------
# Remediation plan
# ---------------------------------------------------------------------------
plan_updates() {
    if check_failed UPD-004 && (( HAVE_SYSTEMD )); then
        plan_add "enable-ntp" safe \
            "Enable time synchronisation (systemd-timesyncd)" \
            "Correct time is required for TLS validation, Kerberos and trustworthy logs." \
            "timedatectl set-ntp true" \
            "Very low. A large initial clock step can briefly confuse time-sensitive apps." \
            "sudo timedatectl set-ntp false" \
            apply_enable_ntp "UPD-004"
    fi
    if check_failed UPD-002; then
        plan_add "unattended-upgrades" review \
            "Install and enable automatic security updates" \
            "Unpatched known vulnerabilities are the most common intrusion vector." \
            "apt-get install unattended-upgrades; write $UH_APT_AUTO_FILE enabling daily security updates (security pocket only, no automatic reboot)." \
            "Low-medium: a security update could theoretically change service behaviour; only the -security pocket is enabled and reboots are never automatic." \
            "sudo $UH_SELF_NAME --rollback <backup-id> (restores $UH_APT_AUTO_FILE)" \
            apply_unattended_upgrades "UPD-002"
    fi
}

apply_enable_ntp() {
    run_cmd "enable NTP" timedatectl set-ntp true
}

apply_unattended_upgrades() {
    if ! pkg_installed unattended-upgrades; then
        apt_install unattended-upgrades || return 1
    fi
    write_managed_file "$UH_APT_AUTO_FILE" \
"// Managed by $UH_NAME
APT::Periodic::Update-Package-Lists \"1\";
APT::Periodic::Unattended-Upgrade \"1\";" 0644 || return 1
    if unit_exists unattended-upgrades.service; then
        run_cmd "enable unattended-upgrades service" systemctl enable unattended-upgrades || true
    fi
    return 0
}
