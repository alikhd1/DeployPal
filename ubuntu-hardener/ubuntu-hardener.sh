#!/usr/bin/env bash
#
# ubuntu-hardener - interactive Ubuntu security audit and hardening tool.
#
# Audits the system, produces a scored report, proposes remediations grouped
# by risk, applies only what you confirm, backs up everything it touches and
# supports rollback by backup ID.
#
# Usage: sudo ./ubuntu-hardener.sh [options]        (see --help)
#
# License: MIT. This tool is NOT a replacement for professional security
# review, backups, monitoring and patch management.

set -Eeuo pipefail
export LC_ALL=C

UH_ARGV="$*"
UH_SELF="$(readlink -f "${BASH_SOURCE[0]}")"
UH_ROOT_DIR="$(cd -- "$(dirname -- "$UH_SELF")" && pwd)"
UH_LIB_DIR="$UH_ROOT_DIR/lib"
UH_SELF_NAME="./$(basename "$UH_SELF")"
CONFIG_FILE="$UH_ROOT_DIR/config/default.conf"

REPORT_DIR_OVERRIDE=""
ROLLBACK_ID=""
LIST_BACKUPS=0

_lib=""
for _lib in common audit report rollback harden_ssh harden_firewall harden_auth \
            harden_permissions harden_services harden_network harden_updates; do
    # shellcheck source=/dev/null
    source "$UH_LIB_DIR/${_lib}.sh"
done

trap 'on_err "$LINENO" "$BASH_COMMAND"' ERR

usage() {
    cat <<EOF
$UH_NAME v$UH_VERSION - interactive Ubuntu security audit & hardening

USAGE:
  sudo $UH_SELF_NAME [options]

MODES:
  (default)            Interactive: audit, then confirm each remediation.
  --audit-only         Audit and report; change nothing.
  --dry-run            Walk the full remediation flow, print every command,
                       change nothing.
  --plan-only          Audit and export the remediation plan; change nothing.
  --interactive        Force interactive mode (default).
  --non-interactive    No prompts. Requires --yes; applies ONLY remediations
                       in the "safe" group. Risky changes are never applied
                       non-interactively.
  --yes, -y            Consent flag required by --non-interactive.
  --rollback ID        Restore the backup session ID (see --list-backups).
  --rollback list      Same as --list-backups.
  --list-backups       Show available backup sessions.

OPTIONS:
  --report DIR         Write reports into DIR (default: $UH_REPORT_ROOT/<ts>).
  --config FILE        Alternative configuration file.
  --verbose, -v        Verbose console output.
  --no-color           Disable colored output.
  --version            Print version.
  --help, -h           This help.

EXAMPLES:
  sudo $UH_SELF_NAME --audit-only
  sudo $UH_SELF_NAME --interactive
  sudo $UH_SELF_NAME --dry-run
  sudo $UH_SELF_NAME --report /tmp/security-report --audit-only
  sudo $UH_SELF_NAME --non-interactive --yes
  sudo $UH_SELF_NAME --list-backups
  sudo $UH_SELF_NAME --rollback 2026-08-25_120000

SAFETY:
  * A scored audit always runs before anything is proposed.
  * Every change is backed up first to $UH_BACKUP_ROOT/<timestamp>/ with a
    manifest (file, backup path, checksum, action, timestamp).
  * SSH changes are validated with 'sshd -t' before reload; on failure the
    original configuration is restored automatically.
  * The firewall is never enabled without an allow rule for the active SSH
    port and an explicit typed confirmation.
  * Nothing is uninstalled or deleted; accounts are locked, never removed.
  * A reboot is never performed automatically.
EOF
}

parse_args() {
    while (( $# )); do
        case "$1" in
            --dry-run)          DRY_RUN=1 ;;
            --audit-only)       AUDIT_ONLY=1 ;;
            --plan-only)        PLAN_ONLY=1 ;;
            --interactive)      INTERACTIVE=1 ;;
            --non-interactive)  INTERACTIVE=0 ;;
            --yes|-y)           ASSUME_YES=1 ;;
            --list-backups)     LIST_BACKUPS=1 ;;
            --rollback)
                shift
                [[ $# -ge 1 ]] || die "--rollback requires a backup ID (or 'list')"
                if [[ "$1" == "list" ]]; then LIST_BACKUPS=1; else ROLLBACK_ID="$1"; fi
                ;;
            --report)
                shift
                [[ $# -ge 1 ]] || die "--report requires a directory"
                REPORT_DIR_OVERRIDE="$1"
                ;;
            --config)
                shift
                [[ $# -ge 1 ]] || die "--config requires a file"
                CONFIG_FILE="$1"
                ;;
            --verbose|-v)       VERBOSE=1 ;;
            --no-color)         USE_COLOR=0 ;;
            --version)          printf '%s %s\n' "$UH_NAME" "$UH_VERSION"; exit 0 ;;
            --help|-h)          usage; exit 0 ;;
            *)                  printf 'Unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
        esac
        shift
    done

    if (( ! INTERACTIVE )) && (( ! ASSUME_YES )) && (( ! AUDIT_ONLY )) && (( ! PLAN_ONLY )) \
       && [[ -z "$ROLLBACK_ID" ]] && (( ! LIST_BACKUPS )); then
        die "--non-interactive requires an explicit --yes (only 'safe'-group remediations are then applied)."
    fi
    if (( INTERACTIVE )) && [[ ! -t 0 ]] && (( ! AUDIT_ONLY )) && (( ! PLAN_ONLY )) && (( ! DRY_RUN )) \
       && [[ -z "$ROLLBACK_ID" ]] && (( ! LIST_BACKUPS )); then
        die "stdin is not a terminal. Run from a TTY, or use --audit-only / --dry-run / --non-interactive --yes."
    fi
}

load_config() {
    if [[ -r "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
        debug "loaded configuration from $CONFIG_FILE"
    else
        die "Configuration file not found: $CONFIG_FILE"
    fi
}

print_banner() {
    printf '%s%s v%s%s - Ubuntu security audit & hardening\n' "$C_BOLD" "$UH_NAME" "$UH_VERSION" "$C_RESET"
    info "Mode: $( (( AUDIT_ONLY )) && printf 'audit-only ' ; (( PLAN_ONLY )) && printf 'plan-only ' ; (( DRY_RUN )) && printf 'DRY-RUN ' ; (( INTERACTIVE )) && printf 'interactive' || printf 'non-interactive' )"
    info "Log file: $UH_LOG_FILE"
    info "This tool is not a replacement for professional security review, backups, monitoring and patch management."
}

write_reports() {
    local phase="$1" prefix="$2"
    generate_markdown_report "$REPORT_DIR/${prefix}report.md" "$phase"
    generate_json_report "$REPORT_DIR/${prefix}report.json" "$phase"
}

# ---------------------------------------------------------------------------
# Remediation runner
# ---------------------------------------------------------------------------
print_plan_item() {
    local id="$1"
    echo
    printf '%s>> %s%s\n' "$C_BOLD" "${UH_PLAN_TITLE[$id]}" "$C_RESET"
    printf '   %-12s %s\n' "Checks:"   "${UH_PLAN_CHECKS[$id]}"
    printf '   %-12s %s\n' "Why:"      "${UH_PLAN_WHY[$id]}"
    printf '   %-12s %s\n' "Changes:"  "${UH_PLAN_CHANGES[$id]}"
    printf '   %-12s %s\n' "Risk:"     "${UH_PLAN_RISK[$id]}"
    printf '   %-12s %s\n' "Rollback:" "${UH_PLAN_ROLLBACK[$id]}"
}

run_plan_item() {
    local id="$1" rc=0
    "${UH_PLAN_FUNC[$id]}" || rc=$?
    case "$rc" in
        0) mark_applied "${UH_PLAN_TITLE[$id]}" ;;
        2) mark_skipped "${UH_PLAN_TITLE[$id]}" ;;
        *) mark_failed "${UH_PLAN_TITLE[$id]} (rc=$rc)" ;;
    esac
}

run_remediation() {
    headline "Remediation"
    if (( ${#UH_PLAN_IDS[@]} == 0 )); then
        ok "No remediations to propose - nothing failed that this tool can fix."
        return 0
    fi

    local group id
    for group in safe review risky; do
        local n
        n="$(plan_count_group "$group")"
        (( n > 0 )) || continue

        local label
        case "$group" in
            safe)   label="Group 1: Safe automatic improvements" ;;
            review) label="Group 2: Requires administrator review" ;;
            risky)  label="Group 3: May affect connectivity or application behaviour" ;;
        esac
        headline "$label ($n item(s))"
        for id in "${UH_PLAN_IDS[@]}"; do
            [[ "${UH_PLAN_GROUP[$id]}" == "$group" ]] || continue
            printf '  - %s\n' "${UH_PLAN_TITLE[$id]}"
        done

        if (( ! INTERACTIVE )) && (( ! DRY_RUN )) && [[ "$group" != "safe" ]]; then
            warn "Non-interactive mode: '$group' group skipped (only 'safe' items are applied with --yes)."
            for id in "${UH_PLAN_IDS[@]}"; do
                [[ "${UH_PLAN_GROUP[$id]}" == "$group" ]] || continue
                mark_skipped "${UH_PLAN_TITLE[$id]}"
            done
            continue
        fi

        if [[ "$group" == "risky" ]] && (( SSH_SESSION_ACTIVE )); then
            warn "You are connected over SSH: items in this group can cut this connection if misconfirmed."
        fi
        if ! confirm "Process the '$group' group now?"; then
            for id in "${UH_PLAN_IDS[@]}"; do
                [[ "${UH_PLAN_GROUP[$id]}" == "$group" ]] || continue
                mark_skipped "${UH_PLAN_TITLE[$id]}"
            done
            continue
        fi

        for id in "${UH_PLAN_IDS[@]}"; do
            [[ "${UH_PLAN_GROUP[$id]}" == "$group" ]] || continue
            print_plan_item "$id"
            local gate="confirm"
            [[ "$group" == "risky" ]] && gate="confirm_risky"
            if "$gate" "Apply: ${UH_PLAN_TITLE[$id]}?"; then
                run_plan_item "$id"
            else
                mark_skipped "${UH_PLAN_TITLE[$id]}"
            fi
        done
    done

    echo
    info "Remediation summary: $APPLIED_COUNT applied, $SKIPPED_COUNT skipped, $FAILED_COUNT failed."
    if [[ -n "$BACKUP_ID" ]]; then
        info "Backups for this run: $BACKUP_DIR"
        info "Rollback anytime with: sudo $UH_SELF_NAME --rollback $BACKUP_ID"
    fi
}

# ---------------------------------------------------------------------------
main() {
    parse_args "$@"
    setup_colors
    require_root
    load_config
    init_logging
    detect_distro
    detect_environment
    detect_ssh_session
    print_banner

    if (( LIST_BACKUPS )); then
        rollback_list
        exit 0
    fi
    if [[ -n "$ROLLBACK_ID" ]]; then
        local rb_rc=0
        run_rollback "$ROLLBACK_ID" || rb_rc=$?
        exit "$rb_rc"
    fi

    init_report_dir

    # ---- Phase 1: audit ---------------------------------------------------
    run_full_audit
    compute_score
    print_findings_table
    print_score_summary
    write_reports "pre-hardening audit" ""

    if (( AUDIT_ONLY )); then
        ok "Audit-only mode: no changes were made."
        exit 0
    fi

    # ---- Phase 2: plan ----------------------------------------------------
    build_plan
    export_remediation_plan "$REPORT_DIR/remediation-plan.md"
    if (( PLAN_ONLY )); then
        ok "Plan-only mode: no changes were made. Review $REPORT_DIR/remediation-plan.md"
        exit 0
    fi

    # ---- Phase 3: apply ---------------------------------------------------
    snapshot_before
    run_remediation

    # ---- Phase 4: post-audit ----------------------------------------------
    if (( DRY_RUN )); then
        echo
        ok "Dry-run complete: no changes were made, so no post-hardening audit is needed."
    elif (( APPLIED_COUNT > 0 )); then
        headline "Post-hardening audit"
        reset_checks
        run_full_audit
        compute_score
        print_score_summary
        write_reports "post-hardening audit" "post-"
        generate_comparison "$REPORT_DIR/comparison.md"
    else
        info "No changes were applied; skipping post-hardening audit."
    fi

    echo
    if (( REBOOT_RECOMMENDED )); then
        warn "A reboot is recommended to fully apply some changes. This tool never reboots automatically."
    fi
    info "Reports: $REPORT_DIR"
    info "Log:     $UH_LOG_FILE"
    if (( SSH_SESSION_ACTIVE )) && (( APPLIED_COUNT > 0 )); then
        warn "Before closing this SSH session, verify you can open a NEW session successfully."
    fi
    ok "Done."
}

main "$@"
