#!/usr/bin/env bash
# lib/harden_ssh.sh - SSH audit and hardening (drop-in based, lockout-aware).
# shellcheck shell=bash

[[ -n "${UH_SSH_LOADED:-}" ]] && return 0
UH_SSH_LOADED=1

UH_SSHD_T=""            # cached `sshd -T` effective configuration
CURRENT_SSH_PORT=22
SSHD_PRESENT=0

# Settings staged for the drop-in file within this run.
declare -gA UH_SSH_SET=()

load_sshd_effective() {
    UH_SSHD_T=""
    SSHD_PRESENT=0
    have sshd || return 0
    SSHD_PRESENT=1
    # -T needs a valid config + host keys; failure leaves checks UNKNOWN.
    UH_SSHD_T="$(sshd -T 2>/dev/null || true)"
    local p
    p="$(sshd_opt port | cut -d, -f1)"
    [[ "$p" =~ ^[0-9]+$ ]] && CURRENT_SSH_PORT="$p"
}

# sshd_opt KEY -> effective value(s), comma-joined, lowercase keys.
sshd_opt() {
    [[ -n "$UH_SSHD_T" ]] || { printf ''; return 0; }
    awk -v k="$1" 'tolower($1)==k { $1=""; sub(/^ /,""); print }' <<<"$UH_SSHD_T" | paste -sd, -
}

# ---------------------------------------------------------------------------
# Audit (category ssh, 15 points)
# ---------------------------------------------------------------------------
audit_ssh() {
    headline "SSH audit"
    load_sshd_effective

    local st ev v

    # SSH-001 service state (informational)
    if (( ! SSHD_PRESENT )); then
        record_check "SSH-001" ssh info 0 INFO "OpenSSH server" \
            "openssh-server not installed - remaining SSH checks skipped" \
            "Nothing to do if remote SSH access is not needed." no
        return 0
    fi
    local running="not running"
    unit_active ssh && running="running"
    unit_active sshd && running="running"
    record_check "SSH-001" ssh info 0 INFO "OpenSSH server" \
        "installed, $running, effective config $([[ -n "$UH_SSHD_T" ]] && echo readable || echo 'NOT readable via sshd -T')" \
        "-" no

    if [[ -z "$UH_SSHD_T" ]]; then
        record_check "SSH-002" ssh high 3 UNKNOWN "Root SSH login disabled" \
            "sshd -T failed; cannot read effective configuration" \
            "Fix sshd configuration errors first (run: sshd -t)." no
        return 0
    fi

    # SSH-002 root login
    v="$(sshd_opt permitrootlogin)"
    case "$v" in
        no|prohibit-password|without-password) st="PASS"; ev="PermitRootLogin=$v" ;;
        *) st="FAIL"; ev="PermitRootLogin=$v" ;;
    esac
    record_check "SSH-002" ssh high 3 "$st" "Root SSH login restricted" "$ev" \
        "Set PermitRootLogin to 'no' (or at least 'prohibit-password') and use sudo from a named account." no

    # SSH-003 password authentication
    v="$(sshd_opt passwordauthentication)"
    if [[ "$v" == "no" ]]; then st="PASS"; else st="FAIL"; fi
    record_check "SSH-003" ssh high 3 "$st" "SSH password authentication disabled" \
        "PasswordAuthentication=$v" \
        "Use SSH keys only: set PasswordAuthentication no AFTER verifying key-based login works." no

    # SSH-004 empty passwords
    v="$(sshd_opt permitemptypasswords)"
    if [[ "$v" == "no" || -z "$v" ]]; then st="PASS"; else st="FAIL"; fi
    record_check "SSH-004" ssh critical 2 "$st" "Empty-password SSH login forbidden" \
        "PermitEmptyPasswords=${v:-no}" \
        "Set PermitEmptyPasswords no." yes

    # SSH-005 port (informational; changing it is opt-in only)
    record_check "SSH-005" ssh info 0 INFO "SSH listening port" \
        "Port(s): $(sshd_opt port)" \
        "A non-default port reduces scanner noise only; not a security boundary. Change only deliberately." no

    # SSH-006 crypto
    local weak="" algs
    algs="$(sshd_opt ciphers),$(sshd_opt macs),$(sshd_opt kexalgorithms)"
    local pat
    for pat in 3des arcfour blowfish cast128 '\-cbc' hmac-md5 'group1-sha1' 'group14-sha1' 'group-exchange-sha1'; do
        if grep -Eq "$pat" <<<"$algs"; then weak+="${pat//\\/} "; fi
    done
    if [[ -n "$weak" ]]; then
        st="FAIL"; ev="weak algorithms offered: $weak"
    else
        st="PASS"; ev="no known-weak ciphers/MACs/KEX offered"
    fi
    record_check "SSH-006" ssh medium 2 "$st" "SSH crypto algorithms" "$ev" \
        "Restrict Ciphers/MACs/KexAlgorithms to modern algorithms (offered as a risky change: old clients may fail to connect)." no

    # SSH-007 PermitUserEnvironment
    v="$(sshd_opt permituserenvironment)"
    if [[ "$v" == "no" || -z "$v" ]]; then st="PASS"; else st="FAIL"; fi
    record_check "SSH-007" ssh low 1 "$st" "PermitUserEnvironment disabled" \
        "PermitUserEnvironment=${v:-no}" "Set PermitUserEnvironment no." yes

    # SSH-008 AllowUsers / AllowGroups
    local au ag
    au="$(sshd_opt allowusers)"; ag="$(sshd_opt allowgroups)"
    if [[ -n "$au" || -n "$ag" ]]; then
        st="PASS"; ev="AllowUsers='$au' AllowGroups='$ag'"
    else
        st="FAIL"; ev="no AllowUsers/AllowGroups restriction configured"
    fi
    record_check "SSH-008" ssh low 1 "$st" "SSH access limited to named users/groups" "$ev" \
        "Manually add 'AllowGroups ssh-users' (create the group, add admins) - not automated because a wrong list locks everyone out." no

    # SSH-009 idle timeout
    local cai cacm
    cai="$(sshd_opt clientaliveinterval)"; cacm="$(sshd_opt clientalivecountmax)"
    if [[ "$cai" =~ ^[0-9]+$ ]] && (( cai > 0 && cai <= 900 )); then
        st="PASS"; ev="ClientAliveInterval=$cai ClientAliveCountMax=$cacm"
    else
        st="FAIL"; ev="ClientAliveInterval=${cai:-0} (no idle timeout)"
    fi
    record_check "SSH-009" ssh low 1 "$st" "SSH idle session timeout" "$ev" \
        "Set ClientAliveInterval $UH_SSH_CLIENT_ALIVE_INTERVAL and ClientAliveCountMax $UH_SSH_CLIENT_ALIVE_COUNT_MAX." yes

    # SSH-010 config file permissions
    local bad="" f mode owner
    for f in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
        [[ -e "$f" ]] || continue
        mode="$(stat -c '%a' "$f")"; owner="$(stat -c '%U' "$f")"
        if [[ "$owner" != "root" ]] || [[ "$mode" =~ [2367].$ ]] || [[ "$mode" =~ [2367]$ ]] || [[ "$mode" != "600" && "$mode" != "644" && "$mode" != "640" ]]; then
            bad+="$f($owner,$mode) "
        fi
        # 644 is Ubuntu's default; CIS prefers 600. Flag only if looser than 644.
    done
    if [[ -n "$bad" ]]; then st="FAIL"; ev="review: $bad"; else st="PASS"; ev="sshd_config and drop-ins are root-owned and not group/world-writable"; fi
    record_check "SSH-010" ssh medium 1 "$st" "SSH configuration file permissions" "$ev" \
        "chown root:root and chmod 600 sshd_config and drop-ins." yes

    # SSH-011 fail2ban for SSH
    if pkg_installed fail2ban; then
        if unit_active fail2ban && fail2ban-client status sshd >/dev/null 2>&1; then
            st="PASS"; ev="fail2ban active with an sshd jail"
        else
            st="FAIL"; ev="fail2ban installed but sshd jail not active"
        fi
    else
        st="FAIL"; ev="fail2ban not installed"
    fi
    record_check "SSH-011" ssh medium 1 "$st" "Brute-force protection (fail2ban) for SSH" "$ev" \
        "Install fail2ban and enable the sshd jail." no

    # SSH-012 misc: MaxAuthTries, X11Forwarding
    local mat x11
    mat="$(sshd_opt maxauthtries)"; x11="$(sshd_opt x11forwarding)"
    if [[ "$mat" =~ ^[0-9]+$ ]] && (( mat <= 4 )) && [[ "$x11" == "no" ]]; then
        st="PASS"
    else
        st="FAIL"
    fi
    record_check "SSH-012" ssh low 1 "$st" "MaxAuthTries <= 4 and X11Forwarding off" \
        "MaxAuthTries=$mat X11Forwarding=$x11" \
        "Set MaxAuthTries $UH_SSH_MAX_AUTH_TRIES, X11Forwarding no, LoginGraceTime $UH_SSH_LOGIN_GRACE_TIME." yes
}

# ---------------------------------------------------------------------------
# Remediation plan
# ---------------------------------------------------------------------------
plan_ssh() {
    (( SSHD_PRESENT )) || return 0

    local safe_ids=""
    check_failed SSH-004 && safe_ids+="SSH-004 "
    check_failed SSH-007 && safe_ids+="SSH-007 "
    check_failed SSH-009 && safe_ids+="SSH-009 "
    check_failed SSH-012 && safe_ids+="SSH-012 "
    if [[ -n "$safe_ids" ]]; then
        plan_add "ssh-safe-settings" safe \
            "Apply safe SSH hardening settings (no auth-method changes)" \
            "Blocks empty-password logins, user-controlled environments, unlimited auth attempts and idle sessions." \
            "Write $UH_SSHD_DROPIN (PermitEmptyPasswords no, PermitUserEnvironment no, ClientAlive*, MaxAuthTries, X11Forwarding no); validate with 'sshd -t'; reload ssh." \
            "Very low. Does not change how you authenticate. Existing sessions are unaffected." \
            "sudo $UH_SELF_NAME --rollback <backup-id>" \
            apply_ssh_safe_settings "$safe_ids"
    fi

    if check_failed SSH-010; then
        plan_add "ssh-config-perms" safe \
            "Tighten SSH configuration file permissions" \
            "Group/world access to sshd_config lets local users read or tamper with SSH policy." \
            "chown root:root, chmod 600 on sshd_config and drop-ins." \
            "Very low." \
            "Restored automatically by --rollback <backup-id>." \
            apply_ssh_config_perms "SSH-010"
    fi

    if check_failed SSH-011; then
        plan_add "install-fail2ban" review \
            "Install fail2ban with an SSH jail" \
            "Slows and blocks SSH brute-force attempts by banning offending IPs." \
            "apt-get install fail2ban; write $UH_F2B_JAIL_FILE (sshd jail, maxretry=$UH_F2B_MAXRETRY, bantime=$UH_F2B_BANTIME); enable service." \
            "Low. A legitimate user who mistypes a password $UH_F2B_MAXRETRY times is banned for $UH_F2B_BANTIME (from that IP only)." \
            "sudo systemctl disable --now fail2ban; sudo apt-get remove fail2ban" \
            apply_install_fail2ban "SSH-011"
    fi

    if check_failed SSH-002; then
        plan_add "ssh-root-login" risky \
            "Disable root SSH login" \
            "Direct root login removes accountability and is the most brute-forced account name." \
            "Set PermitRootLogin no in $UH_SSHD_DROPIN; validate; reload ssh." \
            "MEDIUM: if you currently log in as root over SSH, you must have a working sudo-capable user first. Existing sessions stay open." \
            "sudo $UH_SELF_NAME --rollback <backup-id>" \
            apply_ssh_disable_root "SSH-002"
    fi

    if check_failed SSH-003; then
        plan_add "ssh-password-auth" risky \
            "Disable SSH password authentication (keys only)" \
            "Password guessing is the dominant SSH attack; keys eliminate it." \
            "Set PasswordAuthentication no + KbdInteractiveAuthentication no in $UH_SSHD_DROPIN; validate; reload ssh." \
            "HIGH: users without an installed SSH key are locked out. The tool checks for authorized_keys and warns, but YOU must verify key login works in a second session before confirming." \
            "sudo $UH_SELF_NAME --rollback <backup-id>" \
            apply_ssh_disable_passwords "SSH-003"
    fi

    if check_failed SSH-006; then
        plan_add "ssh-crypto" risky \
            "Restrict SSH ciphers/MACs/key-exchange to modern algorithms" \
            "Legacy algorithms (CBC ciphers, SHA-1 KEX, MD5 MACs) weaken transport security." \
            "Write modern Ciphers/MACs/KexAlgorithms lists to $UH_SSHD_DROPIN; validate; reload ssh." \
            "MEDIUM: very old SSH clients or appliances may no longer connect." \
            "sudo $UH_SELF_NAME --rollback <backup-id>" \
            apply_ssh_crypto "SSH-006"
    fi
}

# ---------------------------------------------------------------------------
# Drop-in management
# ---------------------------------------------------------------------------
ssh_stage() { UH_SSH_SET[$1]="$2"; }

# Regenerate the managed drop-in from everything staged so far, validate,
# reload. On validation failure the original file is restored automatically.
ssh_flush() {
    local key content
    content="# Managed by $UH_NAME. Do not edit; changes are overwritten.
# Rollback: $UH_SELF_NAME --rollback <backup-id>"
    local -a keys=()
    mapfile -t keys < <(printf '%s\n' "${!UH_SSH_SET[@]}" | sort)
    for key in "${keys[@]}"; do
        content+=$'\n'"$key ${UH_SSH_SET[$key]}"
    done

    if [[ -d /etc/ssh/sshd_config.d ]] && grep -qiE '^\s*Include\s+/etc/ssh/sshd_config\.d' /etc/ssh/sshd_config 2>/dev/null; then
        write_managed_file "$UH_SSHD_DROPIN" "$content" 0600 || return 1
    else
        # Old layout without Include support: comment conflicting directives in
        # the main file, then append our block (sshd honours the first value,
        # so conflicts must be commented out first).
        warn "No sshd_config.d Include support detected - editing /etc/ssh/sshd_config directly."
        backup_file /etc/ssh/sshd_config
        if (( ! DRY_RUN )); then
            for key in "${keys[@]}"; do
                sed -ri "s|^\s*(${key}\s+.*)$|# \1  # disabled by $UH_NAME|I" /etc/ssh/sshd_config
            done
            sed -i "/^# BEGIN $UH_NAME/,/^# END $UH_NAME/d" /etc/ssh/sshd_config
            {
                printf '# BEGIN %s\n' "$UH_NAME"
                printf '%s\n' "$content"
                printf '# END %s\n' "$UH_NAME"
            } >> /etc/ssh/sshd_config
        else
            info "[dry-run] would comment conflicting directives and append managed block to /etc/ssh/sshd_config"
        fi
    fi

    ssh_validate_and_reload
}

ssh_validate_and_reload() {
    if (( DRY_RUN )); then
        info "[dry-run] would validate with 'sshd -t' and reload ssh"
        return 0
    fi
    if ! sshd -t 2>>"$UH_LOG_FILE"; then
        error "sshd -t validation FAILED - restoring previous SSH configuration."
        restore_file "$UH_SSHD_DROPIN"
        restore_file /etc/ssh/sshd_config
        if ! sshd -t 2>>"$UH_LOG_FILE"; then
            error "SSH configuration is STILL invalid after restore. DO NOT close this session; inspect /etc/ssh manually."
        fi
        return 1
    fi
    if unit_active ssh || unit_active sshd; then
        run_cmd "reload sshd" systemctl reload ssh 2>/dev/null \
            || run_cmd "reload sshd (sshd unit)" systemctl reload sshd \
            || return 1
        ok "SSH configuration validated and reloaded. Existing sessions are preserved."
        if (( SSH_SESSION_ACTIVE )); then
            warn "Before closing this session, open a NEW terminal and verify you can still log in."
        fi
    else
        info "ssh service not active; configuration will apply on next start."
    fi
    return 0
}

apply_ssh_safe_settings() {
    check_failed SSH-004 && ssh_stage PermitEmptyPasswords no
    check_failed SSH-007 && ssh_stage PermitUserEnvironment no
    if check_failed SSH-009; then
        ssh_stage ClientAliveInterval "$UH_SSH_CLIENT_ALIVE_INTERVAL"
        ssh_stage ClientAliveCountMax "$UH_SSH_CLIENT_ALIVE_COUNT_MAX"
    fi
    if check_failed SSH-012; then
        ssh_stage MaxAuthTries "$UH_SSH_MAX_AUTH_TRIES"
        ssh_stage X11Forwarding no
        ssh_stage LoginGraceTime "$UH_SSH_LOGIN_GRACE_TIME"
    fi
    ssh_flush
}

apply_ssh_config_perms() {
    local f
    for f in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
        [[ -e "$f" ]] || continue
        set_perms "$f" 600 root:root || return 1
    done
    return 0
}

apply_install_fail2ban() {
    if ! pkg_installed fail2ban; then
        apt_install fail2ban || return 1
    fi
    write_managed_file "$UH_F2B_JAIL_FILE" \
"# Managed by $UH_NAME
[sshd]
enabled = true
port = $CURRENT_SSH_PORT
maxretry = $UH_F2B_MAXRETRY
findtime = $UH_F2B_FINDTIME
bantime = $UH_F2B_BANTIME" 0644 || return 1
    if unit_exists fail2ban.service; then
        run_cmd "enable fail2ban" systemctl enable --now fail2ban || return 1
        run_cmd "reload fail2ban" systemctl reload fail2ban || true
    fi
    return 0
}

apply_ssh_disable_root() {
    if (( SSH_SESSION_ACTIVE )) && [[ "$INVOKING_USER" == "root" ]]; then
        warn "You appear to be logged in over SSH as root. Disabling root login WILL lock out this login path."
        confirm_risky "I have a working non-root sudo account and still want to set PermitRootLogin no" || return 2
    fi
    ssh_stage PermitRootLogin no
    ssh_flush
}

apply_ssh_disable_passwords() {
    # Look for at least one authorized_keys file before allowing this.
    local found=0 h
    while IFS=: read -r _ _ uid _ _ home _; do
        [[ "$uid" -ge 1000 && "$uid" -lt 65534 ]] || [[ "$uid" -eq 0 ]] || continue
        h="$home/.ssh/authorized_keys"
        if [[ -s "$h" ]]; then found=1; break; fi
    done < /etc/passwd
    if (( ! found )); then
        error "No non-empty ~/.ssh/authorized_keys found for any login user."
        error "Disabling password authentication now would LOCK YOU OUT. Install a key first (ssh-copy-id), then re-run."
        return 2
    fi
    if (( SSH_SESSION_ACTIVE )); then
        warn "This session is over SSH. Confirm key-based login works from a SECOND session before proceeding."
    fi
    confirm_risky "I verified SSH key login works; disable password authentication now" || return 2
    ssh_stage PasswordAuthentication no
    ssh_stage KbdInteractiveAuthentication no
    ssh_flush
}

apply_ssh_crypto() {
    ssh_stage Ciphers "chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr"
    ssh_stage MACs "hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,hmac-sha2-512,hmac-sha2-256"
    ssh_stage KexAlgorithms "curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512,diffie-hellman-group-exchange-sha256"
    ssh_flush
}
