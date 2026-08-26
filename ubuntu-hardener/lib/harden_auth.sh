#!/usr/bin/env bash
# lib/harden_auth.sh - users, groups, sudo and authentication policy.
# shellcheck shell=bash

[[ -n "${UH_AUTH_LOADED:-}" ]] && return 0
UH_AUTH_LOADED=1

declare -ga UH_HUMAN_USERS=()
declare -ga UH_INACTIVE_USERS=()
declare -ga UH_EMPTY_PW_USERS=()

auth_collect_users() {
    UH_HUMAN_USERS=()
    local user uid shell
    while IFS=: read -r user _ uid _ _ _ shell; do
        if (( uid >= 1000 && uid < 65534 )) && [[ "$shell" != */nologin && "$shell" != */false ]]; then
            UH_HUMAN_USERS+=("$user")
        fi
    done < /etc/passwd
}

# ---------------------------------------------------------------------------
# Audit (category auth, 15 points)
# ---------------------------------------------------------------------------
audit_auth() {
    headline "Users, sudo & authentication audit"
    auth_collect_users

    local st ev

    # AUTH-001 extra UID 0 accounts
    local uid0
    uid0="$(awk -F: '($3==0 && $1!="root"){print $1}' /etc/passwd | paste -sd, - || true)"
    if [[ -n "$uid0" ]]; then
        st="FAIL"; ev="non-root accounts with UID 0: $uid0"
    else
        st="PASS"; ev="only 'root' has UID 0"
    fi
    record_check "AUTH-001" auth critical 3 "$st" "Only root has UID 0" "$ev" \
        "Investigate immediately - additional UID 0 accounts are a classic backdoor. Not automated: requires human judgement." no

    # AUTH-002 empty passwords
    UH_EMPTY_PW_USERS=()
    local eusers=""
    if [[ -r /etc/shadow ]]; then
        while IFS=: read -r user hash _; do
            if [[ -z "$hash" ]]; then
                UH_EMPTY_PW_USERS+=("$user"); eusers+="$user "
            fi
        done < /etc/shadow
        if [[ -n "$eusers" ]]; then st="FAIL"; ev="accounts with EMPTY password field: $eusers"; else st="PASS"; ev="no empty password fields in /etc/shadow"; fi
    else
        st="UNKNOWN"; ev="/etc/shadow not readable"
    fi
    record_check "AUTH-002" auth critical 3 "$st" "No accounts with empty passwords" "$ev" \
        "Lock the account (passwd -l USER) or set a strong password. Locking is offered below per account." no

    # AUTH-003 password aging defaults (login.defs)
    local maxd mind warnd
    maxd="$(awk '/^PASS_MAX_DAYS/{print $2}' /etc/login.defs 2>/dev/null || true)"
    mind="$(awk '/^PASS_MIN_DAYS/{print $2}' /etc/login.defs 2>/dev/null || true)"
    warnd="$(awk '/^PASS_WARN_AGE/{print $2}' /etc/login.defs 2>/dev/null || true)"
    if [[ "$maxd" =~ ^[0-9]+$ ]] && (( maxd <= UH_PASS_MAX_DAYS )) && [[ "$mind" =~ ^[0-9]+$ ]] && (( mind >= UH_PASS_MIN_DAYS )); then
        st="PASS"
    else
        st="FAIL"
    fi
    ev="PASS_MAX_DAYS=${maxd:-?} PASS_MIN_DAYS=${mind:-?} PASS_WARN_AGE=${warnd:-?}"
    record_check "AUTH-003" auth low 1 "$st" "Password aging defaults (login.defs)" "$ev" \
        "Set PASS_MAX_DAYS $UH_PASS_MAX_DAYS, PASS_MIN_DAYS $UH_PASS_MIN_DAYS, PASS_WARN_AGE $UH_PASS_WARN_AGE (affects newly created accounts)." yes

    # AUTH-004 sudoers syntax
    if have visudo; then
        if visudo -c >/dev/null 2>&1; then st="PASS"; ev="visudo -c: parse OK"; else st="FAIL"; ev="visudo -c reports SYNTAX ERRORS"; fi
    else
        st="UNKNOWN"; ev="visudo not available"
    fi
    record_check "AUTH-004" auth medium 1 "$st" "sudoers configuration parses cleanly" "$ev" \
        "Fix with 'visudo' only (never edit /etc/sudoers with a plain editor)." no

    # AUTH-005 broad NOPASSWD rules
    local nopw
    nopw="$(grep -rhsE '^[^#]*NOPASSWD:\s*ALL' /etc/sudoers /etc/sudoers.d/ 2>/dev/null | sed 's/[[:space:]]\+/ /g' | sort -u | head -5 | paste -sd' | ' - || true)"
    if [[ -n "$nopw" ]]; then
        st="FAIL"; ev="$(truncate_text "$nopw" 300)"
        # cloud images legitimately ship e.g. 'ubuntu ALL=(ALL) NOPASSWD:ALL'
        [[ "$CLOUD_HINT" != "none" ]] && ev+=" (common on cloud images - review whether still needed)"
    else
        st="PASS"; ev="no 'NOPASSWD: ALL' rules found"
    fi
    record_check "AUTH-005" auth high 2 "$st" "No passwordless full-sudo rules" "$ev" \
        "Edit with 'visudo -f <file>' and require a password, or scope NOPASSWD to specific commands. Not automated: breaking sudo can lock you out of admin rights." no

    # AUTH-006 PAM password quality
    if pkg_installed libpam-pwquality; then
        local minlen
        minlen="$(grep -Es '^\s*minlen' /etc/security/pwquality.conf 2>/dev/null | tail -1 | awk -F= '{gsub(/ /,"",$2); print $2}' || true)"
        if [[ "$minlen" =~ ^[0-9]+$ ]] && (( minlen >= 12 )); then
            st="PASS"; ev="libpam-pwquality installed, minlen=$minlen"
        else
            st="FAIL"; ev="libpam-pwquality installed but minlen=${minlen:-default(8)}"
        fi
    else
        st="FAIL"; ev="libpam-pwquality not installed (only basic checks apply)"
    fi
    record_check "AUTH-006" auth medium 2 "$st" "Password quality policy (pam_pwquality)" "$ev" \
        "Install libpam-pwquality and set minlen=$UH_PWQUALITY_MINLEN plus complexity credits." no

    # AUTH-007 root password state
    local rootstate
    rootstate="$(passwd -S root 2>/dev/null | awk '{print $2}' || true)"
    case "$rootstate" in
        L|LK) st="PASS"; ev="root password locked (sudo-only administration, Ubuntu default)" ;;
        P|PS) st="FAIL"; ev="root has a usable password (direct root login possible on console/SSH-with-password)" ;;
        NP)   st="FAIL"; ev="root has NO password set" ;;
        *)    st="UNKNOWN"; ev="passwd -S root gave '$rootstate'" ;;
    esac
    record_check "AUTH-007" auth medium 1 "$st" "Direct root password login disabled" "$ev" \
        "Prefer sudo-only administration: 'passwd -l root'. Review first if you rely on console root login (rescue access!). Not automated." no

    # AUTH-008 per-user password aging
    local noage="" user
    if [[ -r /etc/shadow ]]; then
        for user in "${UH_HUMAN_USERS[@]}"; do
            local umax
            umax="$(awk -F: -v u="$user" '$1==u{print $5}' /etc/shadow)"
            if [[ -z "$umax" || "$umax" == "99999" ]]; then noage+="$user "; fi
        done
        if [[ -n "$noage" ]]; then st="FAIL"; ev="human accounts without password expiry: $noage"; else st="PASS"; ev="all human accounts have aging configured"; fi
    else
        st="UNKNOWN"; ev="/etc/shadow not readable"
    fi
    record_check "AUTH-008" auth low 1 "$st" "Existing human accounts have password aging" "$ev" \
        "Apply: chage --maxdays $UH_PASS_MAX_DAYS --mindays $UH_PASS_MIN_DAYS --warndays $UH_PASS_WARN_AGE USER (offered per user)." no

    # AUTH-009 inactive accounts (informational; locking offered)
    UH_INACTIVE_USERS=()
    local inactive=""
    if have lastlog; then
        for user in "${UH_HUMAN_USERS[@]}"; do
            if lastlog -u "$user" -b "$UH_INACTIVE_DAYS" 2>/dev/null | tail -n +2 | grep -q .; then
                UH_INACTIVE_USERS+=("$user"); inactive+="$user "
            fi
        done
    fi
    record_check "AUTH-009" auth info 0 INFO "Human accounts with no login in ${UH_INACTIVE_DAYS}+ days" \
        "${inactive:-none}" \
        "Consider locking unused accounts (offered below); never deleted automatically." no

    # Privileged group membership (informational, folded into evidence)
    local sudoers_members
    sudoers_members="$(getent group sudo adm 2>/dev/null | awk -F: '{print $1"="$4}' | paste -sd' ' - || true)"
    record_check "AUTH-010" auth info 0 INFO "Privileged group membership" \
        "${sudoers_members:-unknown} | human users: ${UH_HUMAN_USERS[*]:-none}" \
        "Keep sudo/adm membership minimal." no
}

# ---------------------------------------------------------------------------
# Remediation plan
# ---------------------------------------------------------------------------
plan_auth() {
    if check_failed AUTH-003; then
        plan_add "login-defs-aging" safe \
            "Set password aging defaults in /etc/login.defs" \
            "Without expiry defaults, newly created accounts keep passwords forever." \
            "PASS_MAX_DAYS=$UH_PASS_MAX_DAYS, PASS_MIN_DAYS=$UH_PASS_MIN_DAYS, PASS_WARN_AGE=$UH_PASS_WARN_AGE in /etc/login.defs. Affects accounts created AFTER this change only." \
            "Very low. Existing accounts are untouched." \
            "sudo $UH_SELF_NAME --rollback <backup-id>" \
            apply_login_defs "AUTH-003"
    fi
    if check_failed AUTH-006; then
        plan_add "pwquality" review \
            "Install pam_pwquality and require stronger passwords" \
            "Users can currently choose weak/short passwords." \
            "apt-get install libpam-pwquality; set minlen=$UH_PWQUALITY_MINLEN, credits for classes, retry=3 in /etc/security/pwquality.conf." \
            "Low. Applies to FUTURE password changes only; existing passwords keep working." \
            "sudo $UH_SELF_NAME --rollback <backup-id> (restores pwquality.conf; package stays installed)" \
            apply_pwquality "AUTH-006"
    fi
    if check_failed AUTH-008; then
        plan_add "user-aging" review \
            "Apply password aging to existing human accounts (per user)" \
            "Accounts listed by AUTH-008 have non-expiring passwords." \
            "chage --maxdays $UH_PASS_MAX_DAYS --mindays $UH_PASS_MIN_DAYS --warndays $UH_PASS_WARN_AGE <user>, each confirmed individually." \
            "Low-medium: service/automation accounts using passwords could eventually expire - confirm per account." \
            "sudo chage --maxdays 99999 --mindays 0 <user>" \
            apply_user_aging "AUTH-008"
    fi
    if (( ${#UH_INACTIVE_USERS[@]} > 0 )) || (( ${#UH_EMPTY_PW_USERS[@]} > 0 )); then
        plan_add "lock-accounts" review \
            "Lock unused or empty-password accounts (per account)" \
            "Idle accounts and accounts without passwords are easy targets." \
            "usermod -L <user> for each account you approve. Accounts are NEVER deleted." \
            "Medium: locking an account someone still uses blocks their login (reversible instantly)." \
            "sudo usermod -U <user>   (also recorded in the rollback manifest)" \
            apply_lock_accounts "AUTH-002 AUTH-009"
    fi
}

apply_login_defs() {
    backup_file /etc/login.defs
    set_conf_kv /etc/login.defs PASS_MAX_DAYS "$UH_PASS_MAX_DAYS" $'\t' || return 1
    set_conf_kv /etc/login.defs PASS_MIN_DAYS "$UH_PASS_MIN_DAYS" $'\t' || return 1
    set_conf_kv /etc/login.defs PASS_WARN_AGE "$UH_PASS_WARN_AGE" $'\t' || return 1
    return 0
}

apply_pwquality() {
    if ! pkg_installed libpam-pwquality; then
        apt_install libpam-pwquality || return 1
    fi
    backup_file /etc/security/pwquality.conf
    set_conf_kv /etc/security/pwquality.conf minlen "$UH_PWQUALITY_MINLEN" || return 1
    set_conf_kv /etc/security/pwquality.conf dcredit "-1" || return 1
    set_conf_kv /etc/security/pwquality.conf ucredit "-1" || return 1
    set_conf_kv /etc/security/pwquality.conf lcredit "-1" || return 1
    set_conf_kv /etc/security/pwquality.conf retry "3" || return 1
    return 0
}

apply_user_aging() {
    local user applied=0
    for user in "${UH_HUMAN_USERS[@]}"; do
        local umax
        umax="$(awk -F: -v u="$user" '$1==u{print $5}' /etc/shadow 2>/dev/null || true)"
        [[ -z "$umax" || "$umax" == "99999" ]] || continue
        if confirm "Apply password aging (max $UH_PASS_MAX_DAYS days) to user '$user'?"; then
            manifest_add "note" "chage:$user" "-" "previous max=${umax:-none}"
            run_cmd "chage $user" chage --maxdays "$UH_PASS_MAX_DAYS" --mindays "$UH_PASS_MIN_DAYS" --warndays "$UH_PASS_WARN_AGE" "$user" || return 1
            applied=$((applied + 1))
        fi
    done
    (( applied > 0 )) || return 2
    return 0
}

apply_lock_accounts() {
    local user applied=0
    for user in "${UH_EMPTY_PW_USERS[@]}" "${UH_INACTIVE_USERS[@]}"; do
        [[ "$user" == "root" ]] && continue
        [[ "$user" == "$INVOKING_USER" ]] && { warn "Not offering to lock the invoking user '$user'."; continue; }
        local state
        state="$(passwd -S "$user" 2>/dev/null | awk '{print $2}' || true)"
        [[ "$state" == "L" || "$state" == "LK" ]] && continue
        if confirm "Lock account '$user' (state=$state)? It will not be deleted and can be unlocked with 'usermod -U $user'."; then
            manifest_add "account-locked" "$user" "-" "prior-state=$state"
            run_cmd "lock account $user" usermod -L "$user" || return 1
            applied=$((applied + 1))
        fi
    done
    (( applied > 0 )) || return 2
    return 0
}
