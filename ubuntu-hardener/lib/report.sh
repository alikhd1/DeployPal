#!/usr/bin/env bash
# lib/report.sh - scoring, console tables, Markdown/JSON reports, comparison.
# shellcheck shell=bash

[[ -n "${UH_REPORT_LOADED:-}" ]] && return 0
UH_REPORT_LOADED=1

SCORE_TOTAL=0
declare -gA CAT_EARNED_W=() CAT_TOTAL_W=() CAT_PASS=() CAT_FAIL=() CAT_UNKNOWN=() CAT_POINTS_EARNED=()

# Before/after snapshot
BEFORE_SCORE=""
declare -gA UH_BEFORE_STATUS=()

REPORT_DIR=""
RUN_STAMP=""

init_report_dir() {
    RUN_STAMP="$(date +%Y-%m-%d_%H%M%S)"
    if [[ -n "${REPORT_DIR_OVERRIDE:-}" ]]; then
        REPORT_DIR="$REPORT_DIR_OVERRIDE"
    else
        REPORT_DIR="$UH_REPORT_ROOT/$RUN_STAMP"
    fi
    mkdir -p "$REPORT_DIR"
    chmod 750 "$REPORT_DIR" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Scoring
# ---------------------------------------------------------------------------
compute_score() {
    CAT_EARNED_W=(); CAT_TOTAL_W=(); CAT_PASS=(); CAT_FAIL=(); CAT_UNKNOWN=(); CAT_POINTS_EARNED=()
    local id cat w st
    for id in "${UH_CHECK_IDS[@]}"; do
        cat="${UH_CHECK_CATEGORY[$id]}"
        w="${UH_CHECK_WEIGHT[$id]}"
        st="${UH_CHECK_STATUS[$id]}"
        case "$st" in
            PASS)    CAT_PASS[$cat]=$(( ${CAT_PASS[$cat]:-0} + 1 )) ;;
            FAIL)    CAT_FAIL[$cat]=$(( ${CAT_FAIL[$cat]:-0} + 1 )) ;;
            UNKNOWN) CAT_UNKNOWN[$cat]=$(( ${CAT_UNKNOWN[$cat]:-0} + 1 )) ;;
        esac
        (( w > 0 )) || continue
        # UNKNOWN/INFO checks are excluded from both numerator and denominator.
        if [[ "$st" == "PASS" ]]; then
            CAT_EARNED_W[$cat]=$(( ${CAT_EARNED_W[$cat]:-0} + w ))
            CAT_TOTAL_W[$cat]=$(( ${CAT_TOTAL_W[$cat]:-0} + w ))
        elif [[ "$st" == "FAIL" ]]; then
            CAT_TOTAL_W[$cat]=$(( ${CAT_TOTAL_W[$cat]:-0} + w ))
        fi
    done

    local cat earned_pts=0 assessed_max=0
    for cat in "${UH_CATEGORY_ORDER[@]}"; do
        local pts="${UH_CATEGORY_POINTS[$cat]}"
        (( pts > 0 )) || continue
        local tw="${CAT_TOTAL_W[$cat]:-0}" ew="${CAT_EARNED_W[$cat]:-0}"
        if (( tw > 0 )); then
            local cpts
            cpts="$(awk -v p="$pts" -v e="$ew" -v t="$tw" 'BEGIN{printf "%.1f", p*e/t}')"
            CAT_POINTS_EARNED[$cat]="$cpts"
            earned_pts="$(awk -v a="$earned_pts" -v b="$cpts" 'BEGIN{printf "%.1f", a+b}')"
            assessed_max=$(( assessed_max + pts ))
        else
            CAT_POINTS_EARNED[$cat]="n/a"
        fi
    done
    if (( assessed_max > 0 )); then
        SCORE_TOTAL="$(awk -v e="$earned_pts" -v m="$assessed_max" 'BEGIN{printf "%d", (100*e/m)+0.5}')"
    else
        SCORE_TOTAL=0
    fi
    UH_ASSESSED_MAX="$assessed_max"
    UH_EARNED_PTS="$earned_pts"
}

snapshot_before() {
    BEFORE_SCORE="$SCORE_TOTAL"
    UH_BEFORE_STATUS=()
    local id
    for id in "${UH_CHECK_IDS[@]}"; do
        UH_BEFORE_STATUS[$id]="${UH_CHECK_STATUS[$id]}"
    done
}

# ---------------------------------------------------------------------------
# Console output
# ---------------------------------------------------------------------------
status_colored() {
    case "$1" in
        PASS)    printf '%s%-7s%s' "$C_GREEN" "PASS" "$C_RESET" ;;
        FAIL)    printf '%s%-7s%s' "$C_RED" "FAIL" "$C_RESET" ;;
        UNKNOWN) printf '%s%-7s%s' "$C_YELLOW" "UNKNOWN" "$C_RESET" ;;
        *)       printf '%s%-7s%s' "$C_CYAN" "INFO" "$C_RESET" ;;
    esac
}

print_findings_table() {
    headline "Findings"
    printf '%s%-10s %-9s %-8s %-9s %s%s\n' "$C_BOLD" "ID" "CATEGORY" "SEV" "STATUS" "CHECK" "$C_RESET"
    printf '%s\n' "-------------------------------------------------------------------------------"
    local id
    for id in "${UH_CHECK_IDS[@]}"; do
        printf '%-10s %-9s %-8s ' "$id" "${UH_CHECK_CATEGORY[$id]}" "${UH_CHECK_SEVERITY[$id]}"
        status_colored "${UH_CHECK_STATUS[$id]}"
        printf '   %s\n' "$(truncate_text "${UH_CHECK_TITLE[$id]}" 48)"
    done

    echo
    info "Details of failed checks:"
    local shown=0
    for id in "${UH_CHECK_IDS[@]}"; do
        [[ "${UH_CHECK_STATUS[$id]}" == "FAIL" ]] || continue
        shown=1
        printf '  %s%s%s [%s/%s]: %s\n' "$C_BOLD" "$id" "$C_RESET" \
            "${UH_CHECK_CATEGORY[$id]}" "${UH_CHECK_SEVERITY[$id]}" "${UH_CHECK_TITLE[$id]}"
        printf '      evidence:    %s\n' "$(truncate_text "${UH_CHECK_EVIDENCE[$id]}" 220)"
        printf '      remediation: %s\n' "$(truncate_text "${UH_CHECK_REMEDIATION[$id]}" 220)"
    done
    (( shown )) || info "  (none)"
}

print_score_summary() {
    headline "Security score"
    printf '%s%-12s %-10s %-22s %s%s\n' "$C_BOLD" "CATEGORY" "POINTS" "PASS/FAIL/UNKNOWN" "" "$C_RESET"
    local cat
    for cat in "${UH_CATEGORY_ORDER[@]}"; do
        local pts="${UH_CATEGORY_POINTS[$cat]}"
        (( pts > 0 )) || continue
        printf '%-12s %-10s %s/%s/%s\n' "$cat" \
            "${CAT_POINTS_EARNED[$cat]:-n/a}/$pts" \
            "${CAT_PASS[$cat]:-0}" "${CAT_FAIL[$cat]:-0}" "${CAT_UNKNOWN[$cat]:-0}"
    done
    echo
    printf '%sOverall score: %s/100%s (assessed: %s of 100 category points)\n' \
        "$C_BOLD" "$SCORE_TOTAL" "$C_RESET" "${UH_ASSESSED_MAX:-100}"
    info "The score is indicative only - it reflects this tool's checks, not a guarantee of security."
}

# ---------------------------------------------------------------------------
# Markdown report
# ---------------------------------------------------------------------------
generate_markdown_report() {
    local out="$1" phase="$2"
    {
        printf '# %s security report (%s)\n\n' "$UH_NAME" "$phase"
        printf -- '- **Host:** %s (%s)\n' "$HOST_NAME" "$OS_PRETTY"
        printf -- '- **Kernel:** %s | **IPs:** %s\n' "$HOST_KERNEL" "$HOST_IPS"
        printf -- '- **Environment:** %s\n' "$(env_description)"
        printf -- '- **Generated:** %s by %s v%s (mode: %s)\n' "$(date -Is)" "$UH_NAME" "$UH_VERSION" "$( (( DRY_RUN )) && echo dry-run || echo live )"
        printf -- '- **Uptime:** %s | **Logged-in users:** %s\n\n' "$HOST_UPTIME" "$HOST_USERS"

        printf '## Score: %s/100\n\n' "$SCORE_TOTAL"
        printf '> The score is indicative, not a guarantee of security. It summarises\n'
        printf '> this tool'"'"'s checks only and is no replacement for professional review,\n'
        printf '> backups, monitoring and patch management.\n\n'
        printf '| Category | Points | Pass | Fail | Unknown |\n|---|---|---|---|---|\n'
        local cat
        for cat in "${UH_CATEGORY_ORDER[@]}"; do
            local pts="${UH_CATEGORY_POINTS[$cat]}"
            (( pts > 0 )) || continue
            printf '| %s | %s/%s | %s | %s | %s |\n' "$cat" \
                "${CAT_POINTS_EARNED[$cat]:-n/a}" "$pts" \
                "${CAT_PASS[$cat]:-0}" "${CAT_FAIL[$cat]:-0}" "${CAT_UNKNOWN[$cat]:-0}"
        done

        printf '\n## Findings\n\n'
        printf '| ID | Category | Severity | Weight | Status | Check | Auto-fix safe |\n|---|---|---|---|---|---|---|\n'
        local id
        for id in "${UH_CHECK_IDS[@]}"; do
            printf '| %s | %s | %s | %s | %s | %s | %s |\n' \
                "$id" "${UH_CHECK_CATEGORY[$id]}" "${UH_CHECK_SEVERITY[$id]}" \
                "${UH_CHECK_WEIGHT[$id]}" "${UH_CHECK_STATUS[$id]}" \
                "${UH_CHECK_TITLE[$id]}" "${UH_CHECK_AUTO[$id]}"
        done

        printf '\n## Details\n'
        for id in "${UH_CHECK_IDS[@]}"; do
            printf '\n### %s - %s\n\n' "$id" "${UH_CHECK_TITLE[$id]}"
            printf -- '- **Status:** %s | **Severity:** %s | **Category:** %s | **Weight:** %s\n' \
                "${UH_CHECK_STATUS[$id]}" "${UH_CHECK_SEVERITY[$id]}" \
                "${UH_CHECK_CATEGORY[$id]}" "${UH_CHECK_WEIGHT[$id]}"
            printf -- '- **Evidence:** %s\n' "${UH_CHECK_EVIDENCE[$id]}"
            printf -- '- **Remediation:** %s\n' "${UH_CHECK_REMEDIATION[$id]}"
            printf -- '- **Safe to automate:** %s\n' "${UH_CHECK_AUTO[$id]}"
        done
        printf '\n---\n*Generated by %s v%s. No secrets, password hashes or private keys are included in this report.*\n' "$UH_NAME" "$UH_VERSION"
    } > "$out"
    chmod 640 "$out" 2>/dev/null || true
    ok "Markdown report: $out"
}

# ---------------------------------------------------------------------------
# JSON report
# ---------------------------------------------------------------------------
generate_json_report() {
    local out="$1" phase="$2"
    {
        printf '{\n'
        printf '  "tool": "%s",\n' "$UH_NAME"
        printf '  "version": "%s",\n' "$UH_VERSION"
        printf '  "phase": "%s",\n' "$(json_escape "$phase")"
        printf '  "generated_at": "%s",\n' "$(date -Is)"
        printf '  "dry_run": %s,\n' "$( (( DRY_RUN )) && echo true || echo false )"
        printf '  "host": {\n'
        printf '    "hostname": "%s",\n' "$(json_escape "$HOST_NAME")"
        printf '    "os": "%s",\n' "$(json_escape "$OS_PRETTY")"
        printf '    "kernel": "%s",\n' "$(json_escape "$HOST_KERNEL")"
        printf '    "ips": "%s",\n' "$(json_escape "$HOST_IPS")"
        printf '    "environment": "%s"\n' "$(json_escape "$(env_description)")"
        printf '  },\n'
        printf '  "score": {\n'
        printf '    "total": %s,\n' "$SCORE_TOTAL"
        printf '    "max": 100,\n'
        printf '    "assessed_points": %s,\n' "${UH_ASSESSED_MAX:-0}"
        printf '    "note": "Indicative only; not a guarantee of security.",\n'
        printf '    "categories": [\n'
        local cat first=1
        for cat in "${UH_CATEGORY_ORDER[@]}"; do
            local pts="${UH_CATEGORY_POINTS[$cat]}"
            (( pts > 0 )) || continue
            (( first )) || printf ',\n'
            first=0
            local earned="${CAT_POINTS_EARNED[$cat]:-null}"
            [[ "$earned" == "n/a" ]] && earned="null"
            printf '      {"name": "%s", "earned": %s, "max": %s, "pass": %s, "fail": %s, "unknown": %s}' \
                "$cat" "$earned" "$pts" "${CAT_PASS[$cat]:-0}" "${CAT_FAIL[$cat]:-0}" "${CAT_UNKNOWN[$cat]:-0}"
        done
        printf '\n    ]\n  },\n'
        printf '  "checks": [\n'
        local id
        first=1
        for id in "${UH_CHECK_IDS[@]}"; do
            (( first )) || printf ',\n'
            first=0
            printf '    {\n'
            printf '      "id": "%s",\n' "$(json_escape "$id")"
            printf '      "category": "%s",\n' "$(json_escape "${UH_CHECK_CATEGORY[$id]}")"
            printf '      "severity": "%s",\n' "$(json_escape "${UH_CHECK_SEVERITY[$id]}")"
            printf '      "weight": %s,\n' "${UH_CHECK_WEIGHT[$id]}"
            printf '      "status": "%s",\n' "$(json_escape "${UH_CHECK_STATUS[$id]}")"
            printf '      "title": "%s",\n' "$(json_escape "${UH_CHECK_TITLE[$id]}")"
            printf '      "evidence": "%s",\n' "$(json_escape "${UH_CHECK_EVIDENCE[$id]}")"
            printf '      "remediation": "%s",\n' "$(json_escape "${UH_CHECK_REMEDIATION[$id]}")"
            printf '      "safe_to_automate": %s\n' "$([[ "${UH_CHECK_AUTO[$id]}" == "yes" ]] && echo true || echo false)"
            printf '    }'
        done
        printf '\n  ]\n}\n'
    } > "$out"
    chmod 640 "$out" 2>/dev/null || true
    ok "JSON report: $out"
}

# ---------------------------------------------------------------------------
# Remediation plan export
# ---------------------------------------------------------------------------
export_remediation_plan() {
    local out="$1"
    {
        printf '# %s remediation plan\n\n' "$UH_NAME"
        printf 'Generated %s for %s. Nothing in this plan has been applied yet.\n' "$(date -Is)" "$HOST_NAME"
        local group id
        for group in safe review risky; do
            local label
            case "$group" in
                safe)   label="Safe automatic improvements" ;;
                review) label="Requires administrator review" ;;
                risky)  label="May affect connectivity or application behaviour" ;;
            esac
            printf '\n## %s\n' "$label"
            local n=0
            for id in "${UH_PLAN_IDS[@]}"; do
                [[ "${UH_PLAN_GROUP[$id]}" == "$group" ]] || continue
                n=$((n + 1))
                printf '\n### %s\n\n' "${UH_PLAN_TITLE[$id]}"
                printf -- '- **Related checks:** %s\n' "${UH_PLAN_CHECKS[$id]}"
                printf -- '- **Why it matters:** %s\n' "${UH_PLAN_WHY[$id]}"
                printf -- '- **What will change:** %s\n' "${UH_PLAN_CHANGES[$id]}"
                printf -- '- **Risk:** %s\n' "${UH_PLAN_RISK[$id]}"
                printf -- '- **Rollback:** %s\n' "${UH_PLAN_ROLLBACK[$id]}"
            done
            (( n > 0 )) || printf '\n(nothing in this group)\n'
        done
    } > "$out"
    chmod 640 "$out" 2>/dev/null || true
    ok "Remediation plan exported: $out"
}

# ---------------------------------------------------------------------------
# Before/after comparison
# ---------------------------------------------------------------------------
generate_comparison() {
    local out="$1"
    headline "Before / after comparison"
    local improved=0 regressed=0 id
    {
        printf '# %s before/after comparison\n\n' "$UH_NAME"
        printf '| | Score |\n|---|---|\n'
        printf '| Before | %s/100 |\n' "$BEFORE_SCORE"
        printf '| After | %s/100 |\n\n' "$SCORE_TOTAL"
        printf '## Changed checks\n\n| ID | Check | Before | After |\n|---|---|---|---|\n'
        for id in "${UH_CHECK_IDS[@]}"; do
            local b="${UH_BEFORE_STATUS[$id]:-NEW}" a="${UH_CHECK_STATUS[$id]}"
            [[ "$b" != "$a" ]] || continue
            printf '| %s | %s | %s | %s |\n' "$id" "${UH_CHECK_TITLE[$id]}" "$b" "$a"
            if [[ "$a" == "PASS" ]]; then improved=$((improved + 1)); fi
            if [[ "$a" == "FAIL" && "$b" == "PASS" ]]; then regressed=$((regressed + 1)); fi
        done
        printf '\n%d check(s) improved, %d regressed.\n' "$improved" "$regressed"
    } > "$out"
    printf '  Score before: %s%s/100%s   after: %s%s/100%s\n' \
        "$C_BOLD" "$BEFORE_SCORE" "$C_RESET" "$C_BOLD" "$SCORE_TOTAL" "$C_RESET"
    for id in "${UH_CHECK_IDS[@]}"; do
        local b="${UH_BEFORE_STATUS[$id]:-NEW}" a="${UH_CHECK_STATUS[$id]}"
        [[ "$b" != "$a" ]] || continue
        printf '  %-10s %s -> %s  %s\n' "$id" "$b" "$a" "$(truncate_text "${UH_CHECK_TITLE[$id]}" 45)"
    done
    ok "Comparison report: $out"
}
