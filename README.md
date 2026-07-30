# DeployPal (`deploypal`)

A self-hosted, single-node infrastructure controller: it **discovers** what is already
running on a Linux server (Nginx vhosts, ports, processes, databases), **provisions**
new applications end-to-end (git clone → build → systemd → Nginx → TLS), **installs**
infrastructure services and admin tools (PostgreSQL, Redis, MySQL/MariaDB, RabbitMQ,
htop, fail2ban, …) from a curated recipe catalog with host-tuned defaults, and
**operates** everything (start/stop/restart, live logs, resource monitoring) from a
React dashboard.

## Components

| Component | Tech | Privilege | Role |
|---|---|---|---|
| `deploypal` orchestrator | Python 3.12 / FastAPI | unprivileged user `deploypal` | Business logic, registry (SQLite), provisioning pipeline, JSON/WS API |
| `deploypal-agent` | **Go** | root (hardened systemd unit) | Narrow, typed system API: /proc, ports, journald, Nginx files, systemd, certbot |
| Frontend | React 18 + TypeScript + Vite | — | Dashboard SPA, served as static files by the orchestrator (or Nginx) |
| State | SQLite (WAL) | owned by `deploypal` | `/var/lib/deploypal/state.db` |
| IPC | gRPC over Unix Domain Socket | `0660 root:deploypal` | `/run/deploypal/agent.sock` |

## Repository layout

```
docs/ARCHITECTURE.md        ← full architecture & data flows (start here)
db/schema.sql               ← SQLite schema
proto/deploypal/agent/v1/       ← gRPC contract between orchestrator and agent
agent/                      ← Go agent (cmd/ + internal/ + gen/ stubs; builds with
                              GOOS=linux CGO_ENABLED=0 → single static binary)
orchestrator/               ← FastAPI orchestrator (app/ + templates/ + gen/ stubs)
frontend/                   ← React dashboard blueprint (component tree + key components)
scripts/gen-protos.{sh,ps1} ← regenerate both languages' stubs from the .proto
```

## Install (Ubuntu 22.04 / 24.04)

As root on the target server:

```bash
git clone https://github.com/alikhd1/DeployPal.git && cd DeployPal
./scripts/setup-ubuntu.sh --email you@example.com
```

The script installs dependencies (nginx, certbot, Go, Node), builds the agent
and dashboard, creates the `deploypal` service user, installs the two hardened
systemd units (`deploypal-agent` as the only root process, `deploypal` as the
unprivileged API), and health-checks the result. Re-running it upgrades in
place. The dashboard binds to `127.0.0.1:8443` — reach it via
`ssh -L 8443:127.0.0.1:8443 root@server` or publish it behind its own nginx
vhost like any app it manages.

## Design principles

1. **Agent = mechanism, orchestrator = policy.** The agent exposes only narrow,
   typed operations (`InstallUnit`, `WriteNginxSite`, `StreamLogs`, …). It never
   executes arbitrary commands. All parsing, decision-making, and state live in
   Python.
2. **Exactly one privileged process.** Only the agent runs as root. The
   orchestrator, builds, and app processes run unprivileged. The UDS is the sole
   privilege boundary and is protected by file permissions **and** an
   `SO_PEERCRED` UID check.
3. **Everything is a recorded pipeline.** Provisioning and deployments run as
   resumable step machines persisted in `deployment_history` — every step, its
   output, and its rollback action are auditable.
4. **Discovery is read-only and idempotent.** Sweeps upsert into the registry and
   never mutate the system.
5. **Package installs are recipe-bound.** The UI can only install what the
   agent's catalog allows: recipes embedded in the agent binary (so the catalog
   upgrades with DeployPal itself) plus root-owned overlays in
   `/etc/deploypal/recipes/`. The orchestrator sends a recipe id and typed
   params — never package names or command lines.
