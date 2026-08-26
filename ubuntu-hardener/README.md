# ubuntu-hardener

An interactive security **audit and hardening** tool for Ubuntu servers and
workstations. It audits the system, produces a **scored report (0–100)**,
proposes remediations **grouped by risk**, applies **only what you confirm**,
**backs up** every file it touches, and supports **rollback by backup ID**.
After hardening it re-audits and shows a **before/after comparison**.

> **Disclaimer.** This tool is *not* a replacement for professional security
> review, off-host backups, monitoring, intrusion detection or patch
> management. The score is indicative only — it summarises this tool's checks
> and is not a guarantee of security.

## Supported platforms

| Platform | Support |
|---|---|
| Ubuntu 20.04 / 22.04 / 24.04 LTS | Tested targets |
| Other Ubuntu releases, Debian, Debian-derivatives | Best-effort (warning shown) |
| Non-Debian distributions | Detected and **refused** — the tool exits without changes |
| Containers | Audit works (kernel/firewall checks report UNKNOWN); hardening of host-owned facilities is skipped |

Requirements: `bash` ≥ 4.4, standard Ubuntu userland (`coreutils`, `awk`,
`sed`, `grep`, `findutils`, `iproute2`). No Python packages are required;
`python3` is only used *optionally* by the smoke test to validate JSON.

## Installation

```bash
git clone <your-repo>/ubuntu-hardener.git
cd ubuntu-hardener
chmod +x ubuntu-hardener.sh tests/smoke-test.sh
sudo ./ubuntu-hardener.sh --audit-only
```

No files are installed anywhere; the tool runs from its directory. It writes
only to `/var/log/ubuntu-hardener/` (logs + reports) and
`/var/backups/ubuntu-hardener/` (backups) — plus whatever changes you
explicitly approve.

## Usage

```bash
sudo ./ubuntu-hardener.sh --audit-only                 # report only, change nothing
sudo ./ubuntu-hardener.sh --interactive                # default: audit, then confirm each fix
sudo ./ubuntu-hardener.sh --dry-run                    # walk the full flow, print every command, change nothing
sudo ./ubuntu-hardener.sh --plan-only                  # audit + export remediation plan, change nothing
sudo ./ubuntu-hardener.sh --report /tmp/security-report --audit-only
sudo ./ubuntu-hardener.sh --non-interactive --yes      # apply ONLY the "safe" group, no prompts
sudo ./ubuntu-hardener.sh --list-backups
sudo ./ubuntu-hardener.sh --rollback 2026-08-25_120000
```

Other flags: `--verbose`, `--no-color`, `--config FILE`, `--version`, `--help`.

### Modes and consent model

| Mode | Prompts | What can be applied |
|---|---|---|
| default / `--interactive` | every group and item | anything you confirm; **risky** items additionally require typing `yes` |
| `--non-interactive --yes` | none | **safe group only**; review/risky items are always skipped |
| `--non-interactive` without `--yes` | — | refused with an error |
| `--dry-run` | none (auto-yes, simulated) | nothing — every command is printed, not executed |
| `--audit-only` / `--plan-only` | none | nothing |

Remediations are grouped as:

1. **Safe automatic improvements** — no auth/connectivity impact
   (sysctl, file permissions, journald persistence, safe SSH settings, …).
2. **Requires administrator review** — package installs, locking accounts,
   disabling services, password policy.
3. **May affect connectivity or application behaviour** — enabling the
   firewall, disabling SSH password auth or root login, SSH crypto policy,
   IPv6 RA. Each requires a typed `yes` and is **never** applied
   non-interactively.

For every proposed item the tool shows: *what will change, why it matters,
affected files/services, risk, and the rollback command* — before asking.

## What gets audited (modules)

| Module | File | Checks |
|---|---|---|
| Baseline | `lib/audit.sh` | OS release/kernel/IPs/users/uptime; VM/container/cloud/desktop detection; Secure Boot; installed security tooling |
| SSH | `lib/harden_ssh.sh` | service state, effective config via `sshd -T`: root login, password auth, empty passwords, port, crypto algorithms, PermitUserEnvironment, AllowUsers/Groups, idle timeout, config permissions, fail2ban, MaxAuthTries/X11 |
| Firewall | `lib/harden_firewall.sh` | ufw/nftables/iptables state, default policies, `ss -tulpn` listener inventory, risky exposed services, ufw logging, SSH rule presence, cloud context |
| Auth | `lib/harden_auth.sh` | UID-0 accounts, empty passwords, login.defs aging, `visudo -c`, `NOPASSWD: ALL` rules, pam_pwquality, root account state, per-user aging, inactive accounts, privileged groups |
| Services | `lib/harden_services.sh` | legacy daemons (telnet/rsh/NIS/tftp/xinetd/rpcbind), desktop services on servers, failed units, world-writable unit/cron files, cron permissions, crontab/at/timer inventory |
| Files | `lib/harden_permissions.sh` | passwd/shadow/gshadow/group/sudoers/crontab permissions, SSH host keys, world-writable files/dirs, SUID/SGID vs baseline, home permissions, tmp mount options |
| Kernel | `lib/harden_network.sh` | rp_filter, ICMP redirects, source routing, SYN cookies, martian logging, ip_forward (unless a container runtime is detected), suid_dumpable, ASLR, kptr/dmesg restrict, IPv6 RA |
| Updates | `lib/harden_updates.sh` | pending security updates, unattended-upgrades, AppArmor, time sync, obsolete packages |
| Logging | `lib/audit.sh` | journald persistence, auditd, log file permissions |

Every check carries an **ID, category, severity (critical/high/medium/low/info),
score weight, status (PASS/FAIL/UNKNOWN/INFO), evidence, remediation text and
a safe-to-automate flag** — all visible in the console, Markdown and JSON
reports. Reports never contain password hashes, private keys or secret file
contents.

## Scoring

100 points are budgeted per category: SSH 15, firewall/network 20,
users/sudo/auth 15, services 15, files/permissions 10, kernel sysctl 10,
updates/tooling 10, logging/auditing 5. Inside a category each scored check
has a weight; the category score is `points × (passed weight / assessable
weight)`. Checks with status UNKNOWN or INFO are excluded from both sides of
the fraction, and categories that could not be assessed at all (e.g. firewall
inside a container) are excluded from the maximum, so the score reflects only
what was actually verified. `examples/` contains a sample Markdown and JSON
report.

## Default hardening rules (what each one does)

**Safe group**

| Action | Change | Why |
|---|---|---|
| SSH safe settings | drop-in `/etc/ssh/sshd_config.d/00-ubuntu-hardener.conf`: `PermitEmptyPasswords no`, `PermitUserEnvironment no`, `ClientAliveInterval 300` / `CountMax 2`, `MaxAuthTries 4`, `X11Forwarding no`, `LoginGraceTime 60` | closes SSH misconfigurations without touching how you authenticate |
| SSH config perms | `chmod 600 root:root` on sshd_config + drop-ins | config not readable/writable by local users |
| ufw SSH rule | `ufw limit <ssh-port>/tcp` when ufw is active without one | prevents lockout on next reload; rate-limits brute force |
| ufw logging | `ufw logging low` | forensic visibility |
| login.defs aging | `PASS_MAX_DAYS 365`, `PASS_MIN_DAYS 1`, `PASS_WARN_AGE 14` | new accounts get expiring passwords (existing accounts untouched) |
| cron/unit perms | remove group/world write on cron and systemd unit files | root-executed files must not be editable by others |
| Sensitive file perms | distribution-default modes on passwd/group/shadow/gshadow/sudoers/crontab/host keys | protects credentials and policy |
| sysctl hardening | approved settings only, written to `/etc/sysctl.d/99-ubuntu-hardener.conf`, per-setting opt-out, applied with `sysctl --system` | anti-spoofing, redirect/source-route rejection, SYN cookies, ASLR, kernel info restrictions |
| journald persistence | `Storage=persistent`, `SystemMaxUse=1G` drop-in + `/var/log/journal` | logs survive reboots |
| time sync | `timedatectl set-ntp true` | accurate time for TLS/auth/logs |

**Review group** — fail2ban (SSH jail), unattended-upgrades (security pocket
only, no auto-reboot), auditd, pam_pwquality (`minlen 12` + class credits),
per-user password aging, locking unused/empty-password accounts (never
deleted), disabling legacy services (packages never removed), world-writable
path fixes, home directory permissions — each item individually confirmed.

**Risky group** — `PermitRootLogin no`, `PasswordAuthentication no` (refused
outright if no `authorized_keys` exists anywhere; typed confirmation
required), modern SSH cipher/MAC/KEX lists, enabling ufw with default-deny
(SSH port auto-detected and required in the allow list), IPv6
router-advertisement rejection. **Never applied non-interactively.**

Deliberately **not** automated (advice only): editing sudoers rules, removing
SUID bits, changing the SSH port, disabling IPv6, AppArmor kernel-cmdline
changes, fstab mount options, deleting users or packages, applying pending
package upgrades, rebooting.

## Backups and rollback

Before any change, originals are copied to
`/var/backups/ubuntu-hardener/<timestamp>/files/<original-path>` and recorded
in `manifest.tsv`: **action, target, backup path, SHA-256 checksum,
timestamp**. Recorded actions include file backups, files *created* by the
tool (rollback deletes them), permission changes (old mode/owner recorded),
service state changes, locked accounts, package installs and prior ufw state.

```bash
sudo ./ubuntu-hardener.sh --list-backups
sudo ./ubuntu-hardener.sh --rollback 2026-08-25_120000
```

Rollback restores entries in reverse order, verifies backup checksums, then
re-validates: `sshd -t` (and reload) if SSH files were restored, `visudo -c`
for sudoers, `sysctl --system` for sysctl, service reloads for
fail2ban/journald. Package installs are *reported* but never auto-removed;
ufw is only disabled on rollback after an explicit typed confirmation.

Validation-before-reload also happens at apply time: if `sshd -t` fails after
a change, the original configuration is restored automatically and the
failure reported.

## Lockout protection (threat model highlights)

- Detects an active SSH session (`SSH_CONNECTION`/`SSH_TTY`/`who am i`) and
  adds explicit warnings + typed confirmations for anything that could cut it.
- Never enables the firewall unless the **detected** SSH port is in the allow
  list; refuses if you remove it.
- Refuses to disable SSH password authentication when no `authorized_keys`
  file exists for any login user.
- `sshd -t` validation with automatic restore before any SSH reload;
  `reload` (not `restart`) is used so existing sessions survive.
- Refuses to lock the invoking user's account; never deletes accounts,
  packages or files; never reboots.
- `apt-get` runs only after checking the dpkg/apt locks and archive
  reachability.
- What this tool does **not** defend against: an already-compromised host
  (it trusts system binaries), kernel exploits, supply-chain attacks, or
  physical access.

## Reports and logs

- Console: findings table, per-category score, failed-check details.
- `report.md` / `report.json` — full pre-hardening audit.
- `post-report.md` / `post-report.json` — post-hardening audit (when changes
  were applied).
- `comparison.md` — before/after score and changed checks.
- `remediation-plan.md` — exported plan (also written when you apply nothing;
  use `--plan-only` to generate it without being prompted).
- Default location `/var/log/ubuntu-hardener/reports/<timestamp>/`, override
  with `--report DIR`.
- Every run logs commands, warnings and results with timestamps to
  `/var/log/ubuntu-hardener/run-<timestamp>.log`.

## Testing

```bash
# Safe smoke test in a throwaway container (no changes to the host):
docker run --rm -v "$PWD:/uh:ro" ubuntu:24.04 bash /uh/tests/smoke-test.sh
```

The smoke test syntax-checks every script, runs `--help`, `--audit-only`,
`--plan-only` and `--dry-run --non-interactive --yes`, validates the JSON
report, and verifies that no backup session was created. Destructive modules
are inherently skipped because nothing is ever applied. Run it on 20.04,
22.04 and 24.04 images to cover all supported releases.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `This tool must run as root` | run with `sudo` |
| `Unsupported distribution` | non-Debian system; the tool exits by design |
| `stdin is not a terminal` | you piped input in interactive mode — use `--non-interactive --yes`, `--audit-only` or a real TTY |
| Many UNKNOWN results | container or `sshd -T` failure; see the evidence column |
| `sshd -t validation FAILED` | the tool already restored the original config; inspect `/etc/ssh` and the run log |
| Package steps skipped | apt/dpkg lock held or no network; see the log |
| Score seems low/high | read `report.md` — every point is traceable to a check |
| Locked out anyway | use console/cloud serial access, then `--rollback <id>`, or manually restore from `/var/backups/ubuntu-hardener/<id>/files/...` |

## Project layout

```
ubuntu-hardener/
├── ubuntu-hardener.sh        # CLI, orchestration, remediation runner
├── lib/
│   ├── common.sh             # logging, prompts, dry-run exec, backups/manifest
│   ├── audit.sh              # check & plan registries, baseline + logging audits
│   ├── harden_ssh.sh         # SSH audit + drop-in hardening
│   ├── harden_firewall.sh    # firewall/exposure audit + UFW enablement
│   ├── harden_auth.sh        # users/sudo/PAM audit + policy hardening
│   ├── harden_permissions.sh # file permission audits + fixes
│   ├── harden_services.sh    # services/cron audit + disable flow
│   ├── harden_network.sh     # sysctl audit + managed sysctl file
│   ├── harden_updates.sh     # updates/AppArmor/NTP audit + tooling installs
│   ├── report.sh             # scoring, console/Markdown/JSON, comparison
│   └── rollback.sh           # manifest-driven rollback
├── config/default.conf       # tunable defaults (paths, ports, policy values)
├── tests/smoke-test.sh       # container-safe smoke test
├── examples/                 # sample Markdown + JSON reports
├── README.md
└── LICENSE                   # MIT
```

## License

MIT — see [LICENSE](LICENSE).
