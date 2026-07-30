#!/usr/bin/env bash
# DeployPal installer for Ubuntu 22.04 / 24.04.
#
# Installs system dependencies, builds the agent and dashboard, creates the
# service user, and starts the two hardened systemd units described in
# docs/ARCHITECTURE.md §7. Idempotent: safe to re-run for upgrades.
#
# Usage (as root on the target server):
#   ./scripts/setup-ubuntu.sh --email you@example.com [--repo URL] [--branch main]
#
#   --email   contact email passed to certbot for app certificates (required)
#   --repo    git URL to install from (default: this checkout if run inside
#             one, otherwise the GitHub repo)
#   --branch  branch to install (default: main)
#
# The dashboard listens on 127.0.0.1:8443. Reach it over an SSH tunnel
#   ssh -L 8443:127.0.0.1:8443 root@server
# or put it behind its own nginx vhost + certbot like any app it manages.
set -euo pipefail

GO_VERSION="1.26.5"
NODE_MAJOR="22"
INSTALL_DIR="/opt/deploypal"
SERVICE_USER="deploypal"
DEFAULT_REPO="https://github.com/alikhd1/DeployPal.git"

EMAIL=""
REPO=""
BRANCH="main"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --email)  EMAIL="$2";  shift 2 ;;
    --repo)   REPO="$2";   shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

log()  { echo -e "\033[1;32m==>\033[0m $*"; }
die()  { echo -e "\033[1;31merror:\033[0m $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root (sudo $0 ...)"
[[ -n "$EMAIL" ]] || die "--email is required (certbot contact address)"
command -v apt-get >/dev/null || die "this installer targets Ubuntu/Debian (apt-get not found)"

# ---------------------------------------------------------------- packages
log "installing system packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git nginx certbot python3-certbot-nginx \
  python3 python3-venv python3-pip curl ca-certificates rsync

# Go: apt's version is too old for the agent's go.mod — install the official
# toolchain (skipped when a new-enough go is already present).
need_go=1
if command -v /usr/local/go/bin/go >/dev/null 2>&1; then
  have=$(/usr/local/go/bin/go version | grep -oP 'go\K[0-9]+\.[0-9]+' | head -1)
  awk -v h="$have" 'BEGIN { split(h, v, "."); exit !(v[1] > 1 || (v[1] == 1 && v[2] >= 25)) }' \
    && need_go=0
fi
if [[ $need_go -eq 1 ]]; then
  log "installing Go ${GO_VERSION}"
  curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tgz
  rm -rf /usr/local/go
  tar -C /usr/local -xzf /tmp/go.tgz
  rm /tmp/go.tgz
fi

# Node: apt's version is too old for Vite/Tailwind v4 — use NodeSource.
if ! command -v node >/dev/null 2>&1 || [[ "$(node -v | grep -oP 'v\K[0-9]+')" -lt 20 ]]; then
  log "installing Node.js ${NODE_MAJOR}.x (NodeSource)"
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
  apt-get install -y -qq nodejs
fi

# ---------------------------------------------------------------- user & dirs
if ! id "$SERVICE_USER" >/dev/null 2>&1; then
  log "creating system user ${SERVICE_USER}"
  useradd --system --create-home --home-dir /var/lib/deploypal \
          --shell /usr/sbin/nologin "$SERVICE_USER"
fi
install -d -o "$SERVICE_USER" -g "$SERVICE_USER" /srv/apps

# Service-catalog dirs: recipes/ is the root-owned overlay an admin can drop
# extra recipe YAMLs into (picked up live, no restart); secrets/ holds
# credentials generated during installs (root-only).
install -d -m 0755 /etc/deploypal /etc/deploypal/recipes
install -d -m 0700 /etc/deploypal/secrets

# ---------------------------------------------------------------- sources
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "$REPO" && -f "$script_dir/../orchestrator/app/main.py" ]]; then
  log "installing from local checkout $(cd "$script_dir/.." && pwd)"
  rsync -a --delete \
    --exclude .git --exclude node_modules --exclude dist \
    --exclude .venv --exclude build --exclude __pycache__ \
    "$script_dir/../" "$INSTALL_DIR/"
elif [[ -d "$INSTALL_DIR/.git" ]]; then
  log "updating $INSTALL_DIR from git"
  git -C "$INSTALL_DIR" fetch origin "$BRANCH"
  git -C "$INSTALL_DIR" reset --hard "origin/$BRANCH"
else
  log "cloning ${REPO:-$DEFAULT_REPO}"
  git clone --branch "$BRANCH" "${REPO:-$DEFAULT_REPO}" "$INSTALL_DIR"
fi

# ---------------------------------------------------------------- build agent
log "building deploypal-agent"
(cd "$INSTALL_DIR/agent" && \
  CGO_ENABLED=0 /usr/local/go/bin/go build -trimpath -ldflags "-s -w" \
    -o /usr/local/bin/deploypal-agent ./cmd/deploypal-agent)

# ---------------------------------------------------------------- orchestrator
log "setting up the orchestrator venv"
python3 -m venv "$INSTALL_DIR/orchestrator/.venv"
"$INSTALL_DIR/orchestrator/.venv/bin/pip" install -q --upgrade pip
"$INSTALL_DIR/orchestrator/.venv/bin/pip" install -q \
  "fastapi>=0.111" "uvicorn[standard]>=0.30" "grpcio>=1.62" \
  "protobuf>=4.25" "aiosqlite>=0.20" "jinja2>=3.1" "httpx>=0.27"

# ---------------------------------------------------------------- frontend
log "building the dashboard"
(cd "$INSTALL_DIR/frontend" && npm ci --no-audit --no-fund --silent && npm run build --silent)

chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"

# ---------------------------------------------------------------- systemd units
log "installing systemd units"
cat > /etc/systemd/system/deploypal-agent.service <<'UNIT'
[Unit]
Description=DeployPal agent (privileged system API)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/deploypal-agent
Restart=on-failure
RestartSec=2
RuntimeDirectory=deploypal
RuntimeDirectoryMode=0750

# The only root process; confine it to exactly what it manages.
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=strict
ReadWritePaths=/etc/nginx /etc/systemd/system /etc/letsencrypt /var/lib/letsencrypt /var/log/letsencrypt

[Install]
WantedBy=multi-user.target
UNIT

cat > /etc/systemd/system/deploypal.service <<UNIT
[Unit]
Description=DeployPal orchestrator (API + dashboard)
After=deploypal-agent.service
Wants=deploypal-agent.service

[Service]
Type=simple
User=${SERVICE_USER}
WorkingDirectory=${INSTALL_DIR}/orchestrator
Environment=DEPLOYPAL_FRONTEND_DIST=${INSTALL_DIR}/frontend/dist
Environment=DEPLOYPAL_CONTACT_EMAIL=${EMAIL}
ExecStart=${INSTALL_DIR}/orchestrator/.venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8443
Restart=on-failure
RestartSec=3
StateDirectory=deploypal

NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=full
ReadWritePaths=/srv/apps

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now deploypal-agent.service
systemctl enable --now deploypal.service

# ---------------------------------------------------------------- health check
log "waiting for the orchestrator"
for _ in $(seq 1 20); do
  if curl -fsS http://127.0.0.1:8443/healthz >/dev/null 2>&1; then
    log "DeployPal is up."
    echo
    echo "  dashboard : http://127.0.0.1:8443  (tunnel: ssh -L 8443:127.0.0.1:8443 root@this-host)"
    echo "  agent     : systemctl status deploypal-agent"
    echo "  api       : systemctl status deploypal"
    echo "  state     : /var/lib/deploypal/state.db"
    exit 0
  fi
  sleep 1
done
die "orchestrator did not become healthy — check: journalctl -u deploypal -n 50"
