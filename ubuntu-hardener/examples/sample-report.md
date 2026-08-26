# ubuntu-hardener security report (pre-hardening audit)

> **Sample report.** Generated on a fictitious Ubuntu 22.04 web server to show
> the report format. Values do not describe a real machine.

- **Host:** web-01 (Ubuntu 22.04.4 LTS)
- **Kernel:** 5.15.0-105-generic | **IPs:** 203.0.113.10 10.0.0.5
- **Environment:** virtual machine (kvm), cloud: cloud-init, server
- **Generated:** 2026-08-25T12:00:00+00:00 by ubuntu-hardener v1.0.0 (mode: live)
- **Uptime:** up 41 days, 3 hours | **Logged-in users:** deploy

## Score: 58/100

> The score is indicative, not a guarantee of security. It summarises
> this tool's checks only and is no replacement for professional review,
> backups, monitoring and patch management.

| Category | Points | Pass | Fail | Unknown |
|---|---|---|---|---|
| ssh | 9.4/15 | 7 | 4 | 0 |
| firewall | 8.0/20 | 2 | 3 | 0 |
| auth | 9.6/15 | 6 | 3 | 0 |
| services | 12.3/15 | 4 | 1 | 0 |
| files | 7.3/10 | 6 | 2 | 0 |
| kernel | 5.6/10 | 9 | 7 | 0 |
| updates | 3.3/10 | 2 | 2 | 0 |
| logging | 3.0/5 | 2 | 1 | 0 |

## Findings

| ID | Category | Severity | Weight | Status | Check | Auto-fix safe |
|---|---|---|---|---|---|---|
| BASE-001 | baseline | info | 0 | INFO | Operating system release | no |
| BASE-002 | baseline | info | 0 | INFO | Runtime environment | no |
| BASE-003 | baseline | low | 0 | UNKNOWN | UEFI Secure Boot | no |
| BASE-004 | baseline | info | 0 | INFO | Installed security tooling | no |
| SSH-001 | ssh | info | 0 | INFO | OpenSSH server | no |
| SSH-002 | ssh | high | 3 | PASS | Root SSH login restricted | no |
| SSH-003 | ssh | high | 3 | FAIL | SSH password authentication disabled | no |
| SSH-004 | ssh | critical | 2 | PASS | Empty-password SSH login forbidden | yes |
| SSH-005 | ssh | info | 0 | INFO | SSH listening port | no |
| SSH-006 | ssh | medium | 2 | PASS | SSH crypto algorithms | no |
| SSH-007 | ssh | low | 1 | PASS | PermitUserEnvironment disabled | yes |
| SSH-008 | ssh | low | 1 | FAIL | SSH access limited to named users/groups | no |
| SSH-009 | ssh | low | 1 | FAIL | SSH idle session timeout | yes |
| SSH-010 | ssh | medium | 1 | PASS | SSH configuration file permissions | yes |
| SSH-011 | ssh | medium | 1 | FAIL | Brute-force protection (fail2ban) for SSH | no |
| SSH-012 | ssh | low | 1 | PASS | MaxAuthTries <= 4 and X11Forwarding off | yes |
| FW-001 | firewall | medium | 2 | PASS | Host firewall (ufw) installed | no |
| FW-002 | firewall | critical | 6 | FAIL | A host firewall is active | no |
| FW-003 | firewall | high | 5 | FAIL | Default inbound policy is deny | no |
| FW-004 | firewall | high | 4 | FAIL | No risky services exposed to the network | no |
| FW-005 | firewall | info | 0 | INFO | Sockets listening on all interfaces | no |
| FW-006 | firewall | low | 1 | UNKNOWN | Firewall logging enabled | no |
| AUTH-001 | auth | critical | 3 | PASS | Only root has UID 0 | no |
| AUTH-002 | auth | critical | 3 | PASS | No accounts with empty passwords | no |
| AUTH-003 | auth | low | 1 | FAIL | Password aging defaults (login.defs) | yes |
| AUTH-005 | auth | high | 2 | FAIL | No passwordless full-sudo rules | no |
| AUTH-006 | auth | medium | 2 | FAIL | Password quality policy (pam_pwquality) | no |
| SVC-001 | services | high | 5 | PASS | No legacy/risky network services | no |
| SVC-003 | services | high | 3 | PASS | Service and cron files are not world-writable | yes |
| UPD-001 | updates | high | 3 | FAIL | No pending security updates | no |
| UPD-002 | updates | high | 3 | FAIL | Automatic security updates | no |
| LOG-001 | logging | medium | 2 | FAIL | Persistent systemd journal | yes |
| ... | | | | | *(remaining checks elided in this sample)* | |

## Details

### SSH-003 - SSH password authentication disabled

- **Status:** FAIL | **Severity:** high | **Category:** ssh | **Weight:** 3
- **Evidence:** PasswordAuthentication=yes
- **Remediation:** Use SSH keys only: set PasswordAuthentication no AFTER verifying key-based login works.
- **Safe to automate:** no

### FW-002 - A host firewall is active

- **Status:** FAIL | **Severity:** critical | **Category:** firewall | **Weight:** 6
- **Evidence:** no active packet filter detected (ufw inactive, no nft/iptables input rules) - cloud security groups may exist (cloud-init) but host firewall is still recommended
- **Remediation:** Enable ufw with default deny incoming after allowing SSH (offered below with lockout protection).
- **Safe to automate:** no

### FW-004 - No risky services exposed to the network

- **Status:** FAIL | **Severity:** high | **Category:** firewall | **Weight:** 4
- **Evidence:** services listening on ALL interfaces: redis-server(tcp/6379)
- **Remediation:** Bind databases/caches to localhost, remove legacy daemons (telnet/ftp/r*), or restrict with firewall rules.
- **Safe to automate:** no

### AUTH-005 - No passwordless full-sudo rules

- **Status:** FAIL | **Severity:** high | **Category:** auth | **Weight:** 2
- **Evidence:** deploy ALL=(ALL) NOPASSWD:ALL (common on cloud images - review whether still needed)
- **Remediation:** Edit with 'visudo -f <file>' and require a password, or scope NOPASSWD to specific commands. Not automated: breaking sudo can lock you out of admin rights.
- **Safe to automate:** no

### LOG-001 - Persistent systemd journal

- **Status:** FAIL | **Severity:** medium | **Category:** logging | **Weight:** 2
- **Evidence:** journald storage: auto(default); /var/log/journal missing - logs are lost at reboot
- **Remediation:** Create /var/log/journal and set Storage=persistent via a journald drop-in.
- **Safe to automate:** yes

*(remaining detail sections elided in this sample)*

---
*Generated by ubuntu-hardener v1.0.0. No secrets, password hashes or private keys are included in this report.*
