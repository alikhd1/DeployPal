#!/usr/bin/env bash
# lib/rollback.sh - restore a previous backup session by ID.
# shellcheck shell=bash

[[ -n "${UH_ROLLBACK_LOADED:-}" ]] && return 0
UH_ROLLBACK_LOADED=1

rollback_list() {
    headline "Available backup sessions"
    if [[ ! -d "$UH_BACKUP_ROOT" ]] || ! ls -1 "$UH_BACKUP_ROOT" 2>/dev/null | grep -q .; then
        info "No backup sessions found under $UH_BACKUP_ROOT."
        return 0
    fi
    local d
    for d in "$UH_BACKUP_ROOT"/*/; do
        [[ -d "$d" ]] || continue
        local id entries
        id="$(basename "$d")"
        entries="$(wc -l < "$d/manifest.tsv" 2>/dev/null | tr -d ' ' || echo 0)"
        printf '  %s  (%s manifest entries)\n' "$id" "$entries"
    done
    echo
    info "Roll back with: sudo $UH_SELF_NAME --rollback <ID>"
}

run_rollback() {
    local id="$1"
    local dir="$UH_BACKUP_ROOT/$id"
    local manifest="$dir/manifest.tsv"

    if [[ ! -f "$manifest" ]]; then
        error "No manifest found for backup ID '$id' ($manifest)."
        rollback_list
        exit 1
    fi

    headline "Rollback of backup session $id"
    info "Manifest actions:"
    awk -F'\t' '{printf "  %-15s %s\n", $1, $2}' "$manifest"
    echo
    if (( SSH_SESSION_ACTIVE )); then
        warn "Active SSH session: restoring SSH/firewall files can affect connectivity."
    fi
    confirm "Restore ALL entries above from backup $id?" || { info "Rollback cancelled."; exit 0; }

    local -a lines=()
    mapfile -t lines < <(tac "$manifest")

    local ssh_touched=0 sudo_touched=0 sysctl_touched=0 f2b_touched=0 journald_touched=0
    local line action target backup extra ts rc_all=0

    for line in "${lines[@]}"; do
        IFS=$'\t' read -r action target backup extra ts <<<"$line"
        debug "rollback entry: $action $target ($ts)"
        case "$action" in
            file-backup)
                if [[ ! -e "$backup" ]]; then
                    error "Backup copy missing: $backup - skipping $target"
                    rc_all=1; continue
                fi
                if [[ -n "$extra" && "$extra" != "-" ]]; then
                    local sum
                    sum="$(sha256sum "$backup" | awk '{print $1}')"
                    if [[ "$sum" != "$extra" ]]; then
                        error "Checksum mismatch for $backup - backup may be corrupted. Skipping $target."
                        rc_all=1; continue
                    fi
                fi
                if (( DRY_RUN )); then
                    info "[dry-run] would restore $target from $backup"
                else
                    cp -a "$backup" "$target" && ok "Restored $target" || { error "Failed to restore $target"; rc_all=1; }
                fi
                ;;
            file-created)
                if [[ -e "$target" ]]; then
                    if (( DRY_RUN )); then
                        info "[dry-run] would remove created file $target"
                    else
                        rm -f -- "$target" && ok "Removed $target (created by that run)" || rc_all=1
                    fi
                fi
                ;;
            perm-change)
                local mode owner group
                IFS=: read -r mode owner group <<<"$extra"
                if [[ -e "$target" && "$mode" != "?" ]]; then
                    if (( DRY_RUN )); then
                        info "[dry-run] would restore $target to mode=$mode owner=$owner:$group"
                    else
                        chmod "$mode" "$target" 2>/dev/null || rc_all=1
                        [[ "$owner" != "?" ]] && chown "$owner:$group" "$target" 2>/dev/null
                        ok "Restored permissions on $target ($mode $owner:$group)"
                    fi
                fi
                ;;
            service-state)
                local was_enabled was_active
                was_enabled="$(grep -o 'enabled=[a-z]*' <<<"$extra" | cut -d= -f2)"
                was_active="$(grep -o 'active=[a-z]*' <<<"$extra" | cut -d= -f2)"
                if (( DRY_RUN )); then
                    info "[dry-run] would restore $target to enabled=$was_enabled active=$was_active"
                    continue
                fi
                if [[ "$was_enabled" == "yes" ]]; then
                    systemctl enable "$target" >>"${UH_LOG_FILE:-/dev/null}" 2>&1 || rc_all=1
                fi
                if [[ "$was_active" == "yes" ]]; then
                    systemctl start "$target" >>"${UH_LOG_FILE:-/dev/null}" 2>&1 || rc_all=1
                fi
                ok "Restored service state of $target (enabled=$was_enabled active=$was_active)"
                ;;
            account-locked)
                if confirm "Unlock account '$target' (was locked by that run)?"; then
                    run_cmd "unlock $target" usermod -U "$target" || rc_all=1
                fi
                ;;
            ufw-state)
                if [[ "$extra" == "inactive" ]] && have ufw; then
                    if confirm_risky "ufw was INACTIVE before that run. Disable ufw now (removes firewall protection)?"; then
                        run_cmd "disable ufw" ufw --force disable || rc_all=1
                    fi
                fi
                ;;
            pkg-install)
                info "Package(s) '$target' were installed by that run. Not auto-removed; if unwanted: sudo apt-get remove $target"
                ;;
            note)
                debug "note entry: $target $extra"
                ;;
            *)
                warn "Unknown manifest action '$action' - skipped."
                ;;
        esac
        case "$target" in
            /etc/ssh/*) ssh_touched=1 ;;
            /etc/sudoers*) sudo_touched=1 ;;
            /etc/sysctl.d/*) sysctl_touched=1 ;;
            /etc/fail2ban/*) f2b_touched=1 ;;
            /etc/systemd/journald.conf*) journald_touched=1 ;;
        esac
    done

    # Post-restore validation and reloads.
    if (( ssh_touched )) && (( ! DRY_RUN )) && have sshd; then
        if sshd -t 2>>"${UH_LOG_FILE:-/dev/null}"; then
            ok "sshd configuration valid after restore."
            { unit_active ssh || unit_active sshd; } && run_cmd "reload sshd" systemctl reload ssh || true
        else
            error "sshd -t FAILS after restore - inspect /etc/ssh before closing this session!"
            rc_all=1
        fi
    fi
    if (( sudo_touched )) && (( ! DRY_RUN )) && have visudo; then
        visudo -c >/dev/null 2>&1 && ok "sudoers valid after restore." || { error "visudo -c FAILS after restore!"; rc_all=1; }
    fi
    if (( sysctl_touched )) && (( ! DRY_RUN )); then
        run_cmd "re-apply sysctl configuration" sysctl --system || true
    fi
    if (( f2b_touched )) && (( ! DRY_RUN )) && unit_active fail2ban; then
        run_cmd "reload fail2ban" systemctl reload fail2ban || true
    fi
    if (( journald_touched )) && (( ! DRY_RUN )) && unit_exists systemd-journald.service; then
        run_cmd "restart systemd-journald" systemctl restart systemd-journald || true
    fi

    echo
    if (( rc_all == 0 )); then
        ok "Rollback of $id completed."
    else
        warn "Rollback of $id completed WITH ERRORS - review messages above and $UH_LOG_FILE."
    fi
    return "$rc_all"
}
