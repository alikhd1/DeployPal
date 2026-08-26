#!/usr/bin/env bash
# lib/common.sh - shared helpers: logging, colors, prompts, dry-run execution,
# platform detection, backups and the rollback manifest.
#
# Sourced by ubuntu-hardener.sh. Not executable on its own.
# shellcheck shell=bash

[[ -n "${UH_COMMON_LOADED:-}" ]] && return 0
UH_COMMON_LOADED=1

UH_VERSION="1.0.0"
UH_NAME="ubuntu-hardener"

# ---------------------------------------------------------------------------
# Runtime flags. The main script overwrites these from CLI arguments.
# ---------------------------------------------------------------------------
DRY_RUN=0
AUDIT_ONLY=0
INTERACTIVE=1
ASSUME_YES=0
PLAN_ONLY=0
VERBOSE=0
USE_COLOR=1

# Path defaults - kept in sync with config/default.conf, which overrides
# them at load_config time. Defined here so --help/--version and early error
# paths never hit unbound variables under `set -u`.
UH_BACKUP_ROOT="/var/backups/ubuntu-hardener"
UH_LOG_DIR="/var/log/ubuntu-hardener"
UH_REPORT_ROOT="/var/log/ubuntu-hardener/reports"

# Environment facts, filled by the detect_* functions.
OS_ID="unknown"
OS_VERSION="unknown"
OS_PRETTY="unknown"
IS_SUPPORTED_UBUNTU=0
IS_DEBIAN_LIKE=0
HAVE_SYSTEMD=0
VIRT_TYPE="unknown"
IS_CONTAINER=0
IS_DESKTOP=0
CLOUD_HINT="none"
SSH_SESSION_ACTIVE=0
INVOKING_USER="${SUDO_USER:-root}"

# Counters
APPLIED_COUNT=0
SKIPPED_COUNT=0
FAILED_COUNT=0
REBOOT_RECOMMENDED=0

# Backup session state
BACKUP_ID=""
BACKUP_DIR=""
declare -gA UH_BACKUP_OF=()   # path -> backup copy path, or "-created-"

UH_LOG_FILE=""

# ---------------------------------------------------------------------------
# Colors and console output
# ---------------------------------------------------------------------------
C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN="" C_MAGENTA=""

setup_colors() {
    local ncolors=0
    [[ -n "${NO_COLOR:-}" ]] && USE_COLOR=0
    if (( USE_COLOR )) && [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
        ncolors=$(tput colors 2>/dev/null || echo 0)
    fi
    if (( USE_COLOR )) && (( ncolors >= 8 )); then
        C_RESET=$(tput sgr0)   C_BOLD=$(tput bold)    C_DIM=$(tput dim 2>/dev/null || true)
        C_RED=$(tput setaf 1)  C_GREEN=$(tput setaf 2) C_YELLOW=$(tput setaf 3)
        C_BLUE=$(tput setaf 4) C_CYAN=$(tput setaf 6)  C_MAGENTA=$(tput setaf 5)
    else
        USE_COLOR=0
    fi
}

# Write one line to the run log only.
log() {
    local level="$1"; shift
    if [[ -n "$UH_LOG_FILE" ]]; then
        printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >> "$UH_LOG_FILE"
    fi
}

info()  { printf '%s[*]%s %s\n' "$C_BLUE"   "$C_RESET" "$*";        log INFO  "$*"; }
ok()    { printf '%s[+]%s %s\n' "$C_GREEN"  "$C_RESET" "$*";        log OK    "$*"; }
warn()  { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2;    log WARN  "$*"; }
error() { printf '%s[x]%s %s\n' "$C_RED"    "$C_RESET" "$*" >&2;    log ERROR "$*"; }
debug() {
    log DEBUG "$*"
    if (( VERBOSE )); then
        printf '%s[.]%s %s\n' "$C_DIM" "$C_RESET" "$*"
    fi
}

headline() {
    printf '\n%s%s== %s ==%s\n' "$C_BOLD" "$C_CYAN" "$*" "$C_RESET"
    log SECTION "$*"
}

die() {
    error "$*"
    exit 1
}

on_err() {
    local line="$1" cmd="$2"
    error "Unexpected error at ${BASH_SOURCE[1]:-?}:${line}: ${cmd}"
    error "See log file: ${UH_LOG_FILE:-<not initialised>}"
}

init_logging() {
    mkdir -p "$UH_LOG_DIR"
    chmod 750 "$UH_LOG_DIR" 2>/dev/null || true
    UH_LOG_FILE="$UH_LOG_DIR/run-$(date +%Y-%m-%d_%H%M%S).log"
    : > "$UH_LOG_FILE"
    chmod 600 "$UH_LOG_FILE"
    log INFO "$UH_NAME v$UH_VERSION started: argv=[$UH_ARGV] user=$INVOKING_USER"
}

# ---------------------------------------------------------------------------
# Prompts
# ---------------------------------------------------------------------------
# confirm "question" -> 0 yes / 1 no.
#  - dry-run: always yes (so the full plan is exercised and printed).
#  - non-interactive: yes only when --yes was given.
confirm() {
    local prompt="$1" reply
    if (( DRY_RUN )); then
        info "[dry-run] assuming YES: $prompt"
        return 0
    fi
    if (( ! INTERACTIVE )); then
        if (( ASSUME_YES )); then
            log CONFIRM "auto-yes (--yes): $prompt"
            return 0
        fi
        log CONFIRM "auto-no (non-interactive without --yes): $prompt"
        return 1
    fi
    while true; do
        printf '%s[?]%s %s [y/N]: ' "$C_MAGENTA" "$C_RESET" "$prompt"
        read -r reply || reply="n"
        case "${reply,,}" in
            y|yes) log CONFIRM "user answered YES: $prompt"; return 0 ;;
            n|no|"") log CONFIRM "user answered NO: $prompt"; return 1 ;;
            *) echo "Please answer 'y' or 'n'." ;;
        esac
    done
}

# confirm_risky "question" -> like confirm, but requires the full word "yes"
# and is NEVER auto-approved in non-interactive mode, even with --yes.
confirm_risky() {
    local prompt="$1" reply
    if (( DRY_RUN )); then
        info "[dry-run] assuming YES (risky): $prompt"
        return 0
    fi
    if (( ! INTERACTIVE )); then
        warn "Skipping (risky changes are never applied non-interactively): $prompt"
        return 1
    fi
    printf '%s[?]%s %s\n' "$C_MAGENTA" "$C_RESET" "$prompt"
    printf "    Type 'yes' to proceed, anything else to skip: "
    read -r reply || reply=""
    if [[ "$reply" == "yes" ]]; then
        log CONFIRM "user typed yes (risky): $prompt"
        return 0
    fi
    log CONFIRM "user declined (risky): $prompt"
    return 1
}

# ask_input "prompt" "default" -> prints the answer (default when
# non-interactive or stdin is not a TTY).
ask_input() {
    local prompt="$1" def="$2" reply
    if (( DRY_RUN )) || (( ! INTERACTIVE )) || [[ ! -t 0 ]]; then
        printf '%s' "$def"
        return 0
    fi
    printf '%s[?]%s %s [%s]: ' "$C_MAGENTA" "$C_RESET" "$prompt" "$def" >&2
    read -r reply || reply=""
    printf '%s' "${reply:-$def}"
}

# ---------------------------------------------------------------------------
# Command execution (dry-run aware). Output goes to the run log.
# ---------------------------------------------------------------------------
run_cmd() {
    local desc="$1"; shift
    log CMD "$desc :: $*"
    if (( DRY_RUN )); then
        info "[dry-run] would run: $*"
        return 0
    fi
    debug "running: $*"
    local rc=0
    "$@" >> "${UH_LOG_FILE:-/dev/null}" 2>&1 || rc=$?
    if (( rc != 0 )); then
        error "Command failed (rc=$rc): $* (see $UH_LOG_FILE)"
        return "$rc"
    fi
    return 0
}

require_root() {
    if (( EUID != 0 )); then
        die "This tool must run as root. Re-run with: sudo $0 ${UH_ARGV}"
    fi
}

have() { command -v "$1" >/dev/null 2>&1; }

pkg_installed() {
    dpkg-query -W -f '${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

unit_exists() {
    (( HAVE_SYSTEMD )) || return 1
    systemctl list-unit-files --full --no-legend "$1" 2>/dev/null | grep -q . && return 0
    # Units generated at runtime (e.g. sysv wrappers) may not appear above.
    systemctl cat -- "$1" >/dev/null 2>&1
}

unit_active()  { (( HAVE_SYSTEMD )) && systemctl is-active  --quiet "$1" 2>/dev/null; }
unit_enabled() { (( HAVE_SYSTEMD )) && systemctl is-enabled --quiet "$1" 2>/dev/null; }

# ---------------------------------------------------------------------------
# Platform detection
# ---------------------------------------------------------------------------
detect_distro() {
    if [[ ! -r /etc/os-release ]]; then
        die "Cannot read /etc/os-release - unsupported system, exiting safely."
    fi
    # shellcheck disable=SC1091
    source /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VERSION="${VERSION_ID:-unknown}"
    OS_PRETTY="${PRETTY_NAME:-unknown}"

    case "$OS_ID" in
        ubuntu)
            IS_DEBIAN_LIKE=1
            case "$OS_VERSION" in
                20.04|22.04|24.04) IS_SUPPORTED_UBUNTU=1 ;;
                *) warn "Ubuntu $OS_VERSION is not a tested release (tested: 20.04/22.04/24.04). Continuing best-effort." ;;
            esac
            ;;
        debian)
            IS_DEBIAN_LIKE=1
            warn "Debian detected. This tool targets Ubuntu LTS; continuing best-effort."
            ;;
        *)
            if [[ " ${ID_LIKE:-} " == *debian* ]] || [[ " ${ID_LIKE:-} " == *ubuntu* ]]; then
                IS_DEBIAN_LIKE=1
                warn "'$OS_PRETTY' is Debian-compatible but untested. Continuing best-effort."
            else
                die "Unsupported distribution: $OS_PRETTY. This tool supports Ubuntu LTS (and Debian-compatible systems). Exiting without changes."
            fi
            ;;
    esac
    debug "distro: id=$OS_ID version=$OS_VERSION supported=$IS_SUPPORTED_UBUNTU"
}

detect_environment() {
    [[ -d /run/systemd/system ]] && HAVE_SYSTEMD=1

    if have systemd-detect-virt; then
        VIRT_TYPE="$(systemd-detect-virt 2>/dev/null || echo unknown)"
        if systemd-detect-virt --container --quiet 2>/dev/null; then
            IS_CONTAINER=1
        fi
    fi
    [[ -f /.dockerenv ]] && { IS_CONTAINER=1; VIRT_TYPE="docker"; }
    if [[ -r /proc/1/environ ]] && tr '\0' '\n' < /proc/1/environ 2>/dev/null | grep -q '^container='; then
        IS_CONTAINER=1
    fi

    # Cloud hint from DMI (best effort; also see /run/cloud-init).
    local vendor="" product=""
    [[ -r /sys/class/dmi/id/sys_vendor ]]   && vendor="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true)"
    [[ -r /sys/class/dmi/id/product_name ]] && product="$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)"
    case "$vendor $product" in
        *Amazon*|*EC2*)        CLOUD_HINT="aws" ;;
        *Google*)              CLOUD_HINT="gcp" ;;
        *Microsoft*)           CLOUD_HINT="azure" ;;
        *DigitalOcean*)        CLOUD_HINT="digitalocean" ;;
        *OpenStack*)           CLOUD_HINT="openstack" ;;
        *Hetzner*)             CLOUD_HINT="hetzner" ;;
        *) [[ -d /run/cloud-init ]] && CLOUD_HINT="cloud-init" ;;
    esac

    if pkg_installed ubuntu-desktop || pkg_installed ubuntu-desktop-minimal; then
        IS_DESKTOP=1
    elif (( HAVE_SYSTEMD )) && [[ "$(systemctl get-default 2>/dev/null || true)" == "graphical.target" ]]; then
        IS_DESKTOP=1
    fi
    debug "environment: virt=$VIRT_TYPE container=$IS_CONTAINER desktop=$IS_DESKTOP cloud=$CLOUD_HINT systemd=$HAVE_SYSTEMD"
}

detect_ssh_session() {
    SSH_SESSION_ACTIVE=0
    if [[ -n "${SSH_CONNECTION:-}" || -n "${SSH_CLIENT:-}" || -n "${SSH_TTY:-}" ]]; then
        SSH_SESSION_ACTIVE=1
    fi
    # sudo strips SSH_* by default; `who am i` still shows the remote host.
    if who am i 2>/dev/null | grep -qE '\([0-9a-fA-F.:]+\)'; then
        SSH_SESSION_ACTIVE=1
    fi
    if (( SSH_SESSION_ACTIVE )); then
        warn "Active SSH session detected. Changes to SSH or the firewall can cut this connection - extra confirmations will be required."
    fi
}

# ---------------------------------------------------------------------------
# apt preflight: never call apt-get blindly.
# ---------------------------------------------------------------------------
apt_locked() {
    local f
    for f in /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock; do
        [[ -e "$f" ]] || continue
        if have fuser && fuser "$f" >/dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}

net_reachable() {
    if have getent && getent hosts archive.ubuntu.com >/dev/null 2>&1; then
        return 0
    fi
    timeout 5 bash -c 'exec 3<>/dev/tcp/archive.ubuntu.com/80 && exec 3>&-' 2>/dev/null
}

apt_preflight() {
    if apt_locked; then
        error "The package manager is locked by another process (apt/dpkg running?). Skipping package operation."
        return 1
    fi
    if ! net_reachable; then
        error "No network connectivity to Ubuntu archives detected. Skipping package operation."
        return 1
    fi
    return 0
}

APT_UPDATED=0
apt_install() {
    if (( DRY_RUN )); then
        info "[dry-run] would apt-get install: $*"
        manifest_add "pkg-install" "$*" "-" "-"
        return 0
    fi
    apt_preflight || return 1
    if (( ! APT_UPDATED )) && (( ! DRY_RUN )); then
        run_cmd "refresh package lists" env DEBIAN_FRONTEND=noninteractive apt-get update -q || return 1
        APT_UPDATED=1
    fi
    run_cmd "install packages: $*" env DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$@" || return 1
    manifest_add "pkg-install" "$*" "-" "-"
    return 0
}

# ---------------------------------------------------------------------------
# Backups and the rollback manifest
# ---------------------------------------------------------------------------
ensure_backup_session() {
    [[ -n "$BACKUP_DIR" ]] && return 0
    BACKUP_ID="$(date +%Y-%m-%d_%H%M%S)"
    BACKUP_DIR="$UH_BACKUP_ROOT/$BACKUP_ID"
    if (( DRY_RUN )); then
        info "[dry-run] would create backup session $BACKUP_DIR"
        return 0
    fi
    mkdir -p "$BACKUP_DIR/files"
    chmod 700 "$UH_BACKUP_ROOT" "$BACKUP_DIR"
    : > "$BACKUP_DIR/manifest.tsv"
    chmod 600 "$BACKUP_DIR/manifest.tsv"
    printf 'tool=%s version=%s host=%s created=%s\n' \
        "$UH_NAME" "$UH_VERSION" "$(hostname)" "$(date -Is)" > "$BACKUP_DIR/session.info"
    info "Backup session: $BACKUP_DIR (rollback with: --rollback $BACKUP_ID)"
}

# manifest_add ACTION TARGET BACKUP_PATH EXTRA
# Actions: file-backup, file-created, perm-change, service-state,
#          account-locked, pkg-install, ufw-state
manifest_add() {
    local action="$1" target="$2" backup="$3" extra="$4"
    ensure_backup_session
    log MANIFEST "$action | $target | $backup | $extra"
    if (( DRY_RUN )); then
        return 0
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$action" "$target" "$backup" "$extra" "$(date -Is)" \
        >> "$BACKUP_DIR/manifest.tsv"
}

# backup_file PATH - copy the current file into the backup session (once per
# run) and record it in the manifest. If the file does not exist yet, record
# that this run creates it, so rollback can delete it.
backup_file() {
    local src="$1"
    if [[ -n "${UH_BACKUP_OF[$src]:-}" ]]; then
        return 0    # already backed up this run; keep the true original
    fi
    if [[ ! -e "$src" ]]; then
        UH_BACKUP_OF[$src]="-created-"
        manifest_add "file-created" "$src" "-" "-"
        return 0
    fi
    ensure_backup_session
    local dest="$BACKUP_DIR/files${src}"
    if (( DRY_RUN )); then
        info "[dry-run] would back up $src -> $dest"
        UH_BACKUP_OF[$src]="$dest"
        return 0
    fi
    mkdir -p "$(dirname "$dest")"
    cp -a "$src" "$dest"
    local sum
    sum="$(sha256sum "$dest" | awk '{print $1}')"
    UH_BACKUP_OF[$src]="$dest"
    manifest_add "file-backup" "$src" "$dest" "$sum"
    debug "backed up $src"
}

# restore_file PATH - undo this run's change to PATH from the session backup.
# Used when validation fails right after a change.
restore_file() {
    local path="$1" b="${UH_BACKUP_OF[$path]:-}"
    if (( DRY_RUN )); then
        info "[dry-run] would restore $path from backup"
        return 0
    fi
    if [[ "$b" == "-created-" ]]; then
        rm -f -- "$path"
        warn "Removed newly created file $path (validation failed)."
    elif [[ -n "$b" && -e "$b" ]]; then
        cp -a "$b" "$path"
        warn "Restored $path from backup (validation failed)."
    else
        error "No backup recorded for $path - cannot auto-restore."
        return 1
    fi
}

# write_managed_file PATH CONTENT [MODE] - backup, then write a file we own.
write_managed_file() {
    local path="$1" content="$2" mode="${3:-0644}"
    backup_file "$path"
    if (( DRY_RUN )); then
        info "[dry-run] would write $path (mode $mode) with content:"
        printf '%s\n' "$content" | sed 's/^/        | /'
        return 0
    fi
    mkdir -p "$(dirname "$path")"
    printf '%s\n' "$content" > "$path"
    chmod "$mode" "$path"
    ok "Wrote $path"
}

# set_perms PATH MODE [OWNER:GROUP] - record old state, then chmod/chown.
set_perms() {
    local path="$1" mode="$2" owner="${3:-}"
    [[ -e "$path" ]] || { warn "set_perms: $path does not exist, skipping"; return 0; }
    local old
    old="$(stat -c '%a:%U:%G' "$path" 2>/dev/null || echo '?:?:?')"
    manifest_add "perm-change" "$path" "-" "$old"
    run_cmd "chmod $mode $path" chmod "$mode" "$path" || return 1
    if [[ -n "$owner" ]]; then
        run_cmd "chown $owner $path" chown "$owner" "$path" || return 1
    fi
    return 0
}

mark_applied() {
    APPLIED_COUNT=$((APPLIED_COUNT + 1))
    ok "Applied: $1"
}

mark_skipped() {
    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    info "Skipped: $1"
}

mark_failed() {
    FAILED_COUNT=$((FAILED_COUNT + 1))
    error "Failed: $1"
}

# ---------------------------------------------------------------------------
# Small utilities
# ---------------------------------------------------------------------------
json_escape() {
    local s="$1"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    s=${s//$'\t'/\\t}
    # Drop any remaining control characters.
    printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037'
}

# truncate_text TEXT MAXLEN
truncate_text() {
    local s="$1" max="$2"
    if (( ${#s} > max )); then
        printf '%s...' "${s:0:max}"
    else
        printf '%s' "$s"
    fi
}

# set_conf_kv FILE KEY VALUE [SEPARATOR]
# Replace "KEY<sep>VALUE" style lines (commented or not) or append. The file
# must already be backed up by the caller.
set_conf_kv() {
    local file="$1" key="$2" value="$3" sep="${4:- = }"
    if (( DRY_RUN )); then
        info "[dry-run] would set '$key$sep$value' in $file"
        return 0
    fi
    touch "$file"
    if grep -Eq "^[#[:space:]]*${key}([[:space:]=]|$)" "$file"; then
        sed -ri "s|^[#[:space:]]*${key}([[:space:]=].*)?$|${key}${sep}${value}|" "$file"
    else
        printf '%s%s%s\n' "$key" "$sep" "$value" >> "$file"
    fi
}
