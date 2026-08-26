#!/usr/bin/env bash
# lib/harden_network.sh - kernel & network sysctl hardening.
# shellcheck shell=bash

[[ -n "${UH_NET_LOADED:-}" ]] && return 0
UH_NET_LOADED=1

# key -> desired value. Filled per-host in audit (IPv6 keys only when present).
declare -gA UH_SYSCTL_DESIRED=()
declare -gA UH_SYSCTL_TITLE=()
declare -gA UH_SYSCTL_RISKY=()      # keys that may affect connectivity
declare -gA UH_SYSCTL_PROPOSED=()   # failed & selected for remediation

sysctl_get() { sysctl -n "$1" 2>/dev/null || printf ''; }

net_define_desired() {
    UH_SYSCTL_DESIRED=(); UH_SYSCTL_TITLE=(); UH_SYSCTL_RISKY=()

    local forwarding_expected=0
    # Container runtimes and routers legitimately forward.
    if have docker || pkg_installed docker.io || pkg_installed docker-ce || \
       pkg_installed lxd || [[ -d /sys/class/net/docker0 ]] || [[ -d /var/lib/kubelet ]]; then
        forwarding_expected=1
    fi
    if (( ! forwarding_expected )); then
        UH_SYSCTL_DESIRED[net.ipv4.ip_forward]=0
        UH_SYSCTL_TITLE[net.ipv4.ip_forward]="IPv4 forwarding disabled (not a router)"
    fi

    UH_SYSCTL_DESIRED[net.ipv4.conf.all.rp_filter]=1
    UH_SYSCTL_TITLE[net.ipv4.conf.all.rp_filter]="Reverse-path filtering (anti-spoofing)"
    UH_SYSCTL_DESIRED[net.ipv4.conf.default.rp_filter]=1
    UH_SYSCTL_TITLE[net.ipv4.conf.default.rp_filter]="Reverse-path filtering (default)"

    UH_SYSCTL_DESIRED[net.ipv4.conf.all.accept_redirects]=0
    UH_SYSCTL_TITLE[net.ipv4.conf.all.accept_redirects]="Ignore ICMP redirects"
    UH_SYSCTL_DESIRED[net.ipv4.conf.default.accept_redirects]=0
    UH_SYSCTL_TITLE[net.ipv4.conf.default.accept_redirects]="Ignore ICMP redirects (default)"
    UH_SYSCTL_DESIRED[net.ipv4.conf.all.send_redirects]=0
    UH_SYSCTL_TITLE[net.ipv4.conf.all.send_redirects]="Do not send ICMP redirects"
    UH_SYSCTL_DESIRED[net.ipv4.conf.default.send_redirects]=0
    UH_SYSCTL_TITLE[net.ipv4.conf.default.send_redirects]="Do not send ICMP redirects (default)"

    UH_SYSCTL_DESIRED[net.ipv4.conf.all.accept_source_route]=0
    UH_SYSCTL_TITLE[net.ipv4.conf.all.accept_source_route]="Reject source-routed packets"
    UH_SYSCTL_DESIRED[net.ipv4.conf.default.accept_source_route]=0
    UH_SYSCTL_TITLE[net.ipv4.conf.default.accept_source_route]="Reject source-routed packets (default)"

    UH_SYSCTL_DESIRED[net.ipv4.tcp_syncookies]=1
    UH_SYSCTL_TITLE[net.ipv4.tcp_syncookies]="SYN-flood cookies"
    UH_SYSCTL_DESIRED[net.ipv4.conf.all.log_martians]=1
    UH_SYSCTL_TITLE[net.ipv4.conf.all.log_martians]="Log martian (impossible-source) packets"

    UH_SYSCTL_DESIRED[fs.suid_dumpable]=0
    UH_SYSCTL_TITLE[fs.suid_dumpable]="No core dumps from SUID programs"
    UH_SYSCTL_DESIRED[kernel.randomize_va_space]=2
    UH_SYSCTL_TITLE[kernel.randomize_va_space]="Full ASLR"
    UH_SYSCTL_DESIRED[kernel.kptr_restrict]=1
    UH_SYSCTL_TITLE[kernel.kptr_restrict]="Hide kernel pointers from unprivileged users"
    UH_SYSCTL_DESIRED[kernel.dmesg_restrict]=1
    UH_SYSCTL_TITLE[kernel.dmesg_restrict]="Restrict dmesg to root"

    if [[ -d /proc/sys/net/ipv6 ]]; then
        UH_SYSCTL_DESIRED[net.ipv6.conf.all.accept_redirects]=0
        UH_SYSCTL_TITLE[net.ipv6.conf.all.accept_redirects]="Ignore ICMPv6 redirects"
        UH_SYSCTL_DESIRED[net.ipv6.conf.default.accept_redirects]=0
        UH_SYSCTL_TITLE[net.ipv6.conf.default.accept_redirects]="Ignore ICMPv6 redirects (default)"
        UH_SYSCTL_DESIRED[net.ipv6.conf.all.accept_source_route]=0
        UH_SYSCTL_TITLE[net.ipv6.conf.all.accept_source_route]="Reject IPv6 source-routed packets"
        # Router advertisements: disabling breaks SLAAC-configured hosts.
        UH_SYSCTL_DESIRED[net.ipv6.conf.all.accept_ra]=0
        UH_SYSCTL_TITLE[net.ipv6.conf.all.accept_ra]="Ignore IPv6 router advertisements (static/DHCP hosts only)"
        UH_SYSCTL_RISKY[net.ipv6.conf.all.accept_ra]=1
    fi
}

# ---------------------------------------------------------------------------
# Audit (category kernel, 10 points)
# ---------------------------------------------------------------------------
audit_kernel() {
    headline "Kernel & network sysctl audit"
    net_define_desired
    UH_SYSCTL_PROPOSED=()

    if (( IS_CONTAINER )); then
        record_check "KRN-000" kernel medium 1 UNKNOWN "Kernel sysctl hardening" \
            "container environment - kernel parameters belong to the host" \
            "Apply sysctl hardening on the container host." no
        return 0
    fi

    local -a keys=()
    mapfile -t keys < <(printf '%s\n' "${!UH_SYSCTL_DESIRED[@]}" | sort)

    local key idx=0
    for key in "${keys[@]}"; do
        idx=$((idx + 1))
        local id want cur st auto="yes"
        id="$(printf 'KRN-%03d' "$idx")"
        want="${UH_SYSCTL_DESIRED[$key]}"
        cur="$(sysctl_get "$key")"
        [[ -n "${UH_SYSCTL_RISKY[$key]:-}" ]] && auto="no"
        if [[ -z "$cur" ]]; then
            st="UNKNOWN"
        elif [[ "$cur" == "$want" ]]; then
            st="PASS"
        else
            st="FAIL"
            UH_SYSCTL_PROPOSED[$key]="$want"
        fi
        record_check "$id" kernel medium 1 "$st" "${UH_SYSCTL_TITLE[$key]}" \
            "$key: current=${cur:-unreadable} desired=$want" \
            "Set $key=$want in $UH_SYSCTL_FILE and apply with 'sysctl --system'." "$auto"
    done

    # Informational: forwarding state when it is expected (container hosts).
    if [[ -z "${UH_SYSCTL_DESIRED[net.ipv4.ip_forward]:-}" ]]; then
        record_check "KRN-FWD" kernel info 0 INFO "IPv4 forwarding" \
            "net.ipv4.ip_forward=$(sysctl_get net.ipv4.ip_forward) (container runtime/router detected; forwarding expected)" \
            "-" no
    fi
}

# ---------------------------------------------------------------------------
# Remediation plan
# ---------------------------------------------------------------------------
plan_kernel() {
    (( IS_CONTAINER )) && return 0
    (( ${#UH_SYSCTL_PROPOSED[@]} > 0 )) || return 0

    local -a safe_keys=() risky_keys=()
    local key
    for key in "${!UH_SYSCTL_PROPOSED[@]}"; do
        if [[ -n "${UH_SYSCTL_RISKY[$key]:-}" ]]; then risky_keys+=("$key"); else safe_keys+=("$key"); fi
    done

    if (( ${#safe_keys[@]} > 0 )); then
        plan_add "sysctl-safe" safe \
            "Apply safe kernel/network sysctl hardening (${#safe_keys[@]} settings)" \
            "Anti-spoofing, redirect/source-route rejection, SYN cookies, ASLR and kernel info restrictions blunt common network and local attacks." \
            "Write only the settings you approve (each shown current -> proposed, per-setting opt-out) to $UH_SYSCTL_FILE; apply with 'sysctl --system'. No other sysctl files are touched." \
            "Very low. These match CIS/Ubuntu guidance and do not affect normal server workloads." \
            "sudo $UH_SELF_NAME --rollback <backup-id> (removes/restores $UH_SYSCTL_FILE, re-runs sysctl --system)" \
            apply_sysctl_safe "kernel"
    fi
    if (( ${#risky_keys[@]} > 0 )); then
        plan_add "sysctl-ra" risky \
            "Ignore IPv6 router advertisements (${#risky_keys[@]} setting)" \
            "Rogue router advertisements can hijack IPv6 traffic on untrusted networks." \
            "Add net.ipv6.conf.*.accept_ra=0 to $UH_SYSCTL_FILE." \
            "MEDIUM: if this host gets its IPv6 address via SLAAC/router advertisements, IPv6 connectivity WILL break. Skip unless IPv6 is static, DHCPv6-managed, or unused." \
            "sudo $UH_SELF_NAME --rollback <backup-id>" \
            apply_sysctl_risky "kernel"
    fi
}

# Shared writer: regenerates the managed sysctl file from approved settings.
declare -gA UH_SYSCTL_ACCEPTED=()

sysctl_flush() {
    (( ${#UH_SYSCTL_ACCEPTED[@]} > 0 )) || { info "No sysctl settings selected."; return 2; }
    local content key
    content="# Managed by $UH_NAME. Only this file is written; other sysctl
# configuration is never modified. Rollback: $UH_SELF_NAME --rollback <id>"
    local -a keys=()
    mapfile -t keys < <(printf '%s\n' "${!UH_SYSCTL_ACCEPTED[@]}" | sort)
    for key in "${keys[@]}"; do
        content+=$'\n'"$key = ${UH_SYSCTL_ACCEPTED[$key]}"
    done
    write_managed_file "$UH_SYSCTL_FILE" "$content" 0644 || return 1
    run_cmd "apply sysctl settings" sysctl --system || return 1
    return 0
}

sysctl_select() {
    local risky_wanted="$1" key
    local -a keys=()
    mapfile -t keys < <(printf '%s\n' "${!UH_SYSCTL_PROPOSED[@]}" | sort)
    for key in "${keys[@]}"; do
        local is_risky=0
        [[ -n "${UH_SYSCTL_RISKY[$key]:-}" ]] && is_risky=1
        (( is_risky == risky_wanted )) || continue
        local cur
        cur="$(sysctl_get "$key")"
        if confirm "Set $key = ${UH_SYSCTL_PROPOSED[$key]} (currently: ${cur:-?}) - ${UH_SYSCTL_TITLE[$key]}?"; then
            UH_SYSCTL_ACCEPTED[$key]="${UH_SYSCTL_PROPOSED[$key]}"
        fi
    done
}

apply_sysctl_safe()  { sysctl_select 0; sysctl_flush; }
apply_sysctl_risky() { sysctl_select 1; sysctl_flush; }
