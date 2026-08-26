#!/usr/bin/env bash
# lib/harden_firewall.sh - firewall & network exposure audit and UFW hardening.
# shellcheck shell=bash

[[ -n "${UH_FW_LOADED:-}" ]] && return 0
UH_FW_LOADED=1

UFW_PRESENT=0
UFW_ACTIVE=0
FIREWALL_ACTIVE=0        # any of ufw / nftables / iptables with rules
LISTEN_TABLE=""          # cached `ss -tulpn` output

fw_collect() {
    UFW_PRESENT=0; UFW_ACTIVE=0; FIREWALL_ACTIVE=0
    if have ufw; then
        UFW_PRESENT=1
        if ufw status 2>/dev/null | head -1 | grep -qi "active"; then
            UFW_ACTIVE=1
            FIREWALL_ACTIVE=1
        fi
    fi
    if (( ! FIREWALL_ACTIVE )) && have nft; then
        local nrules
        nrules="$(nft list ruleset 2>/dev/null | grep -c 'hook input' || true)"
        [[ "$nrules" =~ ^[0-9]+$ ]] && (( nrules > 0 )) && FIREWALL_ACTIVE=1
    fi
    if (( ! FIREWALL_ACTIVE )) && have iptables; then
        local irules
        irules="$(iptables -S INPUT 2>/dev/null | grep -vc '^-P' || true)"
        local ipol
        ipol="$(iptables -S INPUT 2>/dev/null | awk '/^-P INPUT/{print $3}' || true)"
        if [[ "$ipol" == "DROP" || "$ipol" == "REJECT" ]] || { [[ "$irules" =~ ^[0-9]+$ ]] && (( irules > 0 )); }; then
            FIREWALL_ACTIVE=1
        fi
    fi
    LISTEN_TABLE=""
    if have ss; then
        LISTEN_TABLE="$(ss -H -tulpn 2>/dev/null || true)"
    fi
}

# List of "proto:port:process" for sockets bound to all interfaces.
fw_exposed_listeners() {
    [[ -n "$LISTEN_TABLE" ]] || return 0
    awk '{
        proto=$1; addr=$5; proc="";
        if (match($0, /users:\(\("[^"]+"/)) {
            proc=substr($0, RSTART+9, RLENGTH-9); gsub(/"/, "", proc);
        }
        n=split(addr, a, ":"); port=a[n];
        host=substr(addr, 1, length(addr)-length(port)-1);
        if (host=="0.0.0.0" || host=="*" || host=="[::]" || host=="::") {
            printf "%s:%s:%s\n", proto, port, (proc==""?"?":proc);
        }
    }' <<<"$LISTEN_TABLE" | sort -u
}

# ---------------------------------------------------------------------------
# Audit (category firewall, 20 points)
# ---------------------------------------------------------------------------
audit_firewall() {
    headline "Firewall & network exposure audit"
    fw_collect

    local st ev

    if (( IS_CONTAINER )); then
        record_check "FW-001" firewall medium 2 UNKNOWN "Host firewall (ufw) installed" \
            "running inside a container - the firewall belongs to the host" \
            "Manage the firewall on the container host / orchestrator." no
        record_check "FW-002" firewall critical 6 UNKNOWN "A host firewall is active" \
            "container environment" "Manage on the host." no
    else
        # FW-001 ufw installed
        if (( UFW_PRESENT )); then st="PASS"; ev="ufw installed"; else st="FAIL"; ev="ufw not installed"; fi
        record_check "FW-001" firewall medium 2 "$st" "Host firewall (ufw) installed" "$ev" \
            "Install ufw (Uncomplicated Firewall), Ubuntu's standard front-end." no

        # FW-002 some firewall active
        if (( FIREWALL_ACTIVE )); then
            ev="ufw active: $UFW_ACTIVE"
            (( ! UFW_ACTIVE )) && ev="ufw inactive, but nftables/iptables rules present"
            st="PASS"
        else
            st="FAIL"; ev="no active packet filter detected (ufw inactive, no nft/iptables input rules)"
            [[ "$CLOUD_HINT" != "none" ]] && ev+=" - cloud security groups may exist ($CLOUD_HINT) but host firewall is still recommended"
        fi
        record_check "FW-002" firewall critical 6 "$st" "A host firewall is active" "$ev" \
            "Enable ufw with default deny incoming after allowing SSH (offered below with lockout protection)." no
    fi

    # FW-003 default inbound policy
    if (( UFW_ACTIVE )); then
        local pol
        pol="$(ufw status verbose 2>/dev/null | awk -F': ' '/^Default:/{print $2}' || true)"
        if grep -qi "deny (incoming)\|reject (incoming)" <<<"$pol"; then
            st="PASS"; ev="ufw default: $pol"
        else
            st="FAIL"; ev="ufw default: ${pol:-unknown}"
        fi
    elif (( IS_CONTAINER )); then
        st="UNKNOWN"; ev="container environment"
    elif (( FIREWALL_ACTIVE )) && have iptables; then
        local ipol
        ipol="$(iptables -S INPUT 2>/dev/null | awk '/^-P INPUT/{print $3}' || true)"
        if [[ "$ipol" == "DROP" ]]; then st="PASS"; ev="iptables INPUT policy DROP"; else st="UNKNOWN"; ev="iptables INPUT policy ${ipol:-?} (rules may still filter; review manually)"; fi
    else
        st="FAIL"; ev="no firewall, so inbound is implicitly allow-all"
    fi
    record_check "FW-003" firewall high 5 "$st" "Default inbound policy is deny" "$ev" \
        "Default-deny inbound; explicitly allow only required ports." no

    # FW-004 risky exposed services
    local risky="" line proto port proc
    while IFS=: read -r proto port proc; do
        [[ -n "$port" ]] || continue
        case "$proc" in
            telnetd|in.telnetd|vsftpd|proftpd|ftpd|rpcbind|rpc.mountd|redis-server|mongod|memcached|mysqld|mariadbd|postgres|exim4|smbd|snmpd)
                risky+="$proc($proto/$port) " ;;
        esac
        case "$port" in
            23|21|111|512|513|514|2049|6379|11211|27017)
                grep -q "$proc($proto/$port)" <<<"$risky" || risky+="port-$port($proc) " ;;
        esac
    done < <(fw_exposed_listeners)
    if [[ -z "$LISTEN_TABLE" ]]; then
        st="UNKNOWN"; ev="ss not available"
    elif [[ -n "$risky" ]]; then
        st="FAIL"; ev="services listening on ALL interfaces: $risky"
    else
        st="PASS"; ev="no known-risky service exposed on all interfaces"
    fi
    record_check "FW-004" firewall high 4 "$st" "No risky services exposed to the network" "$ev" \
        "Bind databases/caches to localhost, remove legacy daemons (telnet/ftp/r*), or restrict with firewall rules." no

    # FW-005 listening inventory (informational)
    local listeners
    listeners="$(fw_exposed_listeners | paste -sd' ' - || true)"
    record_check "FW-005" firewall info 0 INFO "Sockets listening on all interfaces" \
        "$(truncate_text "${listeners:-none}" 400)" \
        "Review each listener; anything not needed externally should bind to 127.0.0.1." no

    # FW-006 ufw logging
    if (( UFW_ACTIVE )); then
        if ufw status verbose 2>/dev/null | grep -qi "^Logging: on"; then
            st="PASS"; ev="ufw logging on"
        else
            st="FAIL"; ev="ufw logging off"
        fi
        record_check "FW-006" firewall low 1 "$st" "Firewall logging enabled" "$ev" "ufw logging low" yes
    else
        record_check "FW-006" firewall low 1 UNKNOWN "Firewall logging enabled" "ufw not active" "-" no
    fi

    # FW-007 SSH allowed through active firewall
    if (( UFW_ACTIVE )) && (( SSHD_PRESENT )); then
        if ufw status 2>/dev/null | grep -qE "(^| )${CURRENT_SSH_PORT}(/tcp)?\s+(ALLOW|LIMIT)"; then
            st="PASS"; ev="ufw allows port $CURRENT_SSH_PORT"
        else
            st="FAIL"; ev="ufw is active but has NO allow rule for SSH port $CURRENT_SSH_PORT - a reload could cut remote access"
        fi
        record_check "FW-007" firewall medium 2 "$st" "SSH port allowed through the firewall" "$ev" \
            "Add: ufw limit ${CURRENT_SSH_PORT}/tcp (allow with rate-limit)." yes
    fi
}

# ---------------------------------------------------------------------------
# Remediation plan
# ---------------------------------------------------------------------------
plan_firewall() {
    (( IS_CONTAINER )) && return 0

    if check_failed FW-007; then
        plan_add "ufw-ssh-rule" safe \
            "Add an allow (rate-limited) rule for the SSH port to ufw" \
            "The firewall is active without an SSH rule; the next reload/reboot could cut remote access." \
            "ufw limit ${CURRENT_SSH_PORT}/tcp" \
            "None - this only ADDS access (with brute-force rate limiting)." \
            "sudo ufw delete limit ${CURRENT_SSH_PORT}/tcp" \
            apply_ufw_ssh_rule "FW-007"
    fi

    if check_failed FW-006 && (( UFW_ACTIVE )); then
        plan_add "ufw-logging" safe \
            "Enable ufw logging (low)" \
            "Firewall logs are needed to investigate scans and intrusions." \
            "ufw logging low" \
            "Very low. Slight log volume increase." \
            "sudo ufw logging off" \
            apply_ufw_logging "FW-006"
    fi

    if check_failed FW-002 || check_failed FW-003; then
        plan_add "ufw-enable" risky \
            "Enable UFW with default-deny incoming (SSH preserved)" \
            "Without a default-deny firewall every listening service is reachable from anywhere." \
            "Install ufw if missing; back up /etc/ufw; allow SSH port $CURRENT_SSH_PORT (rate-limited) plus ports you approve; set default deny incoming / allow outgoing; enable." \
            "HIGH if you skip a port an application needs. SSH port is detected and added first; you must confirm the final rule list. Cloud users: security groups still apply independently." \
            "sudo ufw disable  (and $UH_SELF_NAME --rollback <backup-id> restores /etc/ufw)" \
            apply_ufw_enable "FW-002 FW-003"
    fi
}

apply_ufw_ssh_rule() {
    run_cmd "ufw limit ${CURRENT_SSH_PORT}/tcp" ufw limit "${CURRENT_SSH_PORT}/tcp" comment "SSH ($UH_NAME)"
}

apply_ufw_logging() {
    run_cmd "ufw logging low" ufw logging low
}

apply_ufw_enable() {
    if (( ! UFW_PRESENT )); then
        confirm "ufw is not installed. Install it now?" || return 2
        apt_install ufw || return 1
        UFW_PRESENT=1
    fi

    # Build and confirm the port list.
    local ports="" p
    (( SSHD_PRESENT )) && ports="$CURRENT_SSH_PORT"
    for p in $UH_ALLOWED_TCP_PORTS; do
        [[ " $ports " == *" $p "* ]] || ports+=" $p"
    done
    ports="$(ask_input "TCP ports to allow inbound (space separated)" "${ports:-22}")"

    echo
    info "UFW will be enabled with:"
    info "  default deny incoming / $UH_UFW_DEFAULT_OUTGOING outgoing"
    for p in $ports; do
        if [[ "$p" == "$CURRENT_SSH_PORT" ]]; then
            info "  limit ${p}/tcp   <- SSH (rate-limited allow)"
        else
            info "  allow ${p}/tcp"
        fi
    done
    if (( SSHD_PRESENT )) && [[ " $ports " != *" $CURRENT_SSH_PORT "* ]]; then
        error "The detected SSH port $CURRENT_SSH_PORT is NOT in the allow list. Refusing to continue - this would lock out remote access."
        return 2
    fi
    if (( SSH_SESSION_ACTIVE )); then
        warn "You are connected over SSH. If the allow list above is wrong, you WILL be disconnected."
    fi
    confirm_risky "Enable UFW now with the rules listed above" || return 2

    # Back up current ufw state and config.
    local f
    manifest_add "ufw-state" "ufw" "-" "$( (( UFW_ACTIVE )) && echo active || echo inactive )"
    for f in /etc/ufw/ufw.conf /etc/ufw/user.rules /etc/ufw/user6.rules; do
        [[ -e "$f" ]] && backup_file "$f"
    done

    run_cmd "ufw default deny incoming" ufw default deny incoming || return 1
    run_cmd "ufw default $UH_UFW_DEFAULT_OUTGOING outgoing" ufw default "$UH_UFW_DEFAULT_OUTGOING" outgoing || return 1
    for p in $ports; do
        if [[ "$p" == "$CURRENT_SSH_PORT" ]]; then
            run_cmd "ufw limit ${p}/tcp" ufw limit "${p}/tcp" comment "SSH ($UH_NAME)" || return 1
        else
            run_cmd "ufw allow ${p}/tcp" ufw allow "${p}/tcp" comment "($UH_NAME)" || return 1
        fi
    done
    run_cmd "enable ufw" ufw --force enable || return 1
    run_cmd "ufw logging low" ufw logging low || true

    if (( ! DRY_RUN )); then
        if ufw status 2>/dev/null | head -1 | grep -qi active; then
            ok "UFW is active. Verify remote access from a NEW session before closing this one."
            UFW_ACTIVE=1; FIREWALL_ACTIVE=1
        else
            error "UFW does not report active after enable - check 'ufw status verbose'."
            return 1
        fi
    fi
    return 0
}
