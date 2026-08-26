#!/usr/bin/env bash
#
# tests/smoke-test.sh - safe smoke test for ubuntu-hardener.
#
# Designed to run inside a disposable Ubuntu Docker container as root:
#
#   docker run --rm -v "$PWD:/uh:ro" ubuntu:24.04 bash /uh/tests/smoke-test.sh
#
# It never applies changes: only --help/--version, --audit-only, --plan-only
# and --dry-run are exercised. Destructive modules are inherently skipped
# because nothing outside dry-run is invoked. On non-Linux or non-root hosts
# the execution steps are skipped and only static checks run.

set -Eeuo pipefail

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$TESTS_DIR")"
MAIN="$ROOT_DIR/ubuntu-hardener.sh"
OUT_DIR="${TMPDIR:-/tmp}/uh-smoke-$$"

PASS=0
FAIL=0
SKIP=0

t_pass() { printf '  [PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
t_fail() { printf '  [FAIL] %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
t_skip() { printf '  [SKIP] %s\n' "$1"; SKIP=$((SKIP + 1)); }

section() { printf '\n== %s ==\n' "$1"; }

# ---------------------------------------------------------------------------
section "Static checks"

for f in "$MAIN" "$ROOT_DIR"/lib/*.sh "$TESTS_DIR"/smoke-test.sh; do
    if bash -n "$f" 2>/dev/null; then
        t_pass "bash -n $(basename "$f")"
    else
        t_fail "bash -n $(basename "$f")"
        bash -n "$f" || true
    fi
done

if command -v shellcheck >/dev/null 2>&1; then
    # Informational: shellcheck findings do not fail the smoke test, but are shown.
    if shellcheck -x -S warning "$MAIN" "$ROOT_DIR"/lib/*.sh; then
        t_pass "shellcheck (no warnings at level 'warning')"
    else
        t_skip "shellcheck reported findings (informational, shown above)"
    fi
else
    t_skip "shellcheck not installed"
fi

for f in "$ROOT_DIR/config/default.conf" "$ROOT_DIR/README.md" "$ROOT_DIR/LICENSE"; do
    if [[ -r "$f" ]]; then t_pass "exists: $(basename "$f")"; else t_fail "missing: $f"; fi
done

# ---------------------------------------------------------------------------
section "Execution checks"

if [[ "$(uname -s)" != "Linux" ]]; then
    t_skip "not Linux - execution checks skipped"
elif [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    t_skip "not root - execution checks skipped (run in a container as root)"
else
    mkdir -p "$OUT_DIR"

    if bash "$MAIN" --help >/dev/null; then t_pass "--help"; else t_fail "--help"; fi
    if bash "$MAIN" --version >/dev/null; then t_pass "--version"; else t_fail "--version"; fi

    # Unknown option must exit non-zero.
    if bash "$MAIN" --definitely-not-an-option >/dev/null 2>&1; then
        t_fail "unknown option should be rejected"
    else
        t_pass "unknown option rejected"
    fi

    # --non-interactive without --yes must be refused.
    if bash "$MAIN" --non-interactive >/dev/null 2>&1; then
        t_fail "--non-interactive without --yes should be refused"
    else
        t_pass "--non-interactive without --yes refused"
    fi

    # Audit-only: must not change anything and must produce reports.
    if bash "$MAIN" --audit-only --no-color --report "$OUT_DIR/audit" > "$OUT_DIR/audit.log" 2>&1; then
        t_pass "--audit-only run"
    else
        t_fail "--audit-only run (see $OUT_DIR/audit.log)"
        tail -30 "$OUT_DIR/audit.log" || true
    fi
    for f in report.md report.json; do
        if [[ -s "$OUT_DIR/audit/$f" ]]; then t_pass "report generated: $f"; else t_fail "report missing: $f"; fi
    done
    if grep -q "Overall score" "$OUT_DIR/audit.log" || grep -q '"total"' "$OUT_DIR/audit/report.json" 2>/dev/null; then
        t_pass "score computed"
    else
        t_fail "score not found in output"
    fi
    if command -v python3 >/dev/null 2>&1; then
        if python3 -m json.tool "$OUT_DIR/audit/report.json" >/dev/null 2>&1; then
            t_pass "report.json is valid JSON"
        else
            t_fail "report.json is NOT valid JSON"
        fi
    else
        t_skip "python3 not available for JSON validation"
    fi

    # Plan-only: audit + exported remediation plan, no changes.
    if bash "$MAIN" --plan-only --non-interactive --no-color --report "$OUT_DIR/plan" > "$OUT_DIR/plan.log" 2>&1; then
        t_pass "--plan-only run"
    else
        t_fail "--plan-only run (see $OUT_DIR/plan.log)"
        tail -30 "$OUT_DIR/plan.log" || true
    fi
    if [[ -s "$OUT_DIR/plan/remediation-plan.md" ]]; then
        t_pass "remediation plan exported"
    else
        t_fail "remediation plan missing"
    fi

    # Dry-run, non-interactive: walks the full flow, applies nothing.
    if bash "$MAIN" --dry-run --non-interactive --yes --no-color --report "$OUT_DIR/dry" > "$OUT_DIR/dry.log" 2>&1; then
        t_pass "--dry-run --non-interactive --yes run"
    else
        t_fail "--dry-run run (see $OUT_DIR/dry.log)"
        tail -30 "$OUT_DIR/dry.log" || true
    fi
    if grep -q "no changes were made" "$OUT_DIR/dry.log"; then
        t_pass "dry-run confirms no changes"
    else
        t_fail "dry-run did not confirm 'no changes'"
    fi
    # A dry run must not create a real backup session directory.
    if [[ -d /var/backups/ubuntu-hardener ]] && ls -1 /var/backups/ubuntu-hardener 2>/dev/null | grep -q .; then
        t_fail "dry-run created a real backup session"
    else
        t_pass "dry-run created no backup session"
    fi

    # Rollback listing on a clean system.
    if bash "$MAIN" --list-backups --no-color > "$OUT_DIR/backups.log" 2>&1; then
        t_pass "--list-backups run"
    else
        t_fail "--list-backups run"
    fi

    # Logs are written.
    if ls /var/log/ubuntu-hardener/run-*.log >/dev/null 2>&1; then
        t_pass "run logs written to /var/log/ubuntu-hardener/"
    else
        t_fail "no run logs found"
    fi
fi

# ---------------------------------------------------------------------------
section "Result"
printf 'passed=%d failed=%d skipped=%d\n' "$PASS" "$FAIL" "$SKIP"
if (( FAIL > 0 )); then
    exit 1
fi
echo "SMOKE TEST OK"
