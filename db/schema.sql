-- DeployPal (smise-navi) — SQLite schema
-- Location: /var/lib/smise-navi/state.db
-- Opened with: PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;
-- The orchestrator is the single writer; the agent never touches the DB.

------------------------------------------------------------------------------
-- projects: one row per application, whether provisioned by us or discovered.
------------------------------------------------------------------------------
CREATE TABLE projects (
    id               INTEGER PRIMARY KEY,
    alias            TEXT    NOT NULL UNIQUE COLLATE NOCASE,   -- user-facing name, [a-z0-9-]{2,40}
    origin           TEXT    NOT NULL DEFAULT 'provisioned'
                     CHECK (origin IN ('provisioned','discovered','adopted')),
    -- source
    git_url          TEXT,                                     -- NULL for discovered apps
    git_branch       TEXT    DEFAULT 'main',
    root_dir         TEXT    NOT NULL,                          -- /srv/apps/<alias> or discovered cwd
    stack            TEXT    NOT NULL DEFAULT 'unknown'
                     CHECK (stack IN ('node','python','go','static','docker','unknown')),
    stack_detail     TEXT,                                      -- JSON: {"framework":"nextjs","node":"20",...}
    -- runtime
    port             INTEGER UNIQUE CHECK (port BETWEEN 1 AND 65535),  -- reserved local port
    start_command    TEXT,                                      -- ExecStart payload
    systemd_unit     TEXT    UNIQUE,                            -- smise-app-<alias>.service
    env_file         TEXT,                                      -- path to managed env file
    -- edge
    domain           TEXT,                                      -- primary public domain
    tls_enabled      INTEGER NOT NULL DEFAULT 0 CHECK (tls_enabled IN (0,1)),
    cert_expires_at  TEXT,                                      -- ISO8601, from certbot metadata
    -- lifecycle
    status           TEXT    NOT NULL DEFAULT 'new'
                     CHECK (status IN ('new','provisioning','running','stopped',
                                       'failed','degraded','archived')),
    last_seen_at     TEXT,                                      -- last discovery sweep that saw it alive
    created_at       TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    updated_at       TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

CREATE INDEX idx_projects_status ON projects(status);

------------------------------------------------------------------------------
-- nginx_routes: parsed edge routing, refreshed by every discovery sweep.
-- A project can serve several domains; a domain can route paths to projects.
------------------------------------------------------------------------------
CREATE TABLE nginx_routes (
    id             INTEGER PRIMARY KEY,
    project_id     INTEGER REFERENCES projects(id) ON DELETE SET NULL,
    server_name    TEXT    NOT NULL,                            -- api.example.com
    listen_port    INTEGER NOT NULL DEFAULT 443,
    location_path  TEXT    NOT NULL DEFAULT '/',
    upstream       TEXT    NOT NULL,                            -- http://127.0.0.1:3007
    upstream_port  INTEGER,                                     -- extracted for joins
    config_file    TEXT    NOT NULL,                            -- /etc/nginx/sites-available/x.conf
    is_enabled     INTEGER NOT NULL DEFAULT 1 CHECK (is_enabled IN (0,1)),
    is_managed     INTEGER NOT NULL DEFAULT 0 CHECK (is_managed IN (0,1)),  -- written by us?
    discovered_at  TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    UNIQUE (server_name, listen_port, location_path)
);

CREATE INDEX idx_routes_upstream_port ON nginx_routes(upstream_port);

------------------------------------------------------------------------------
-- dependencies: infrastructure services (databases, caches, brokers) present
-- on the host — discovered from listening ports or docker.
------------------------------------------------------------------------------
CREATE TABLE dependencies (
    id            INTEGER PRIMARY KEY,
    kind          TEXT    NOT NULL
                  CHECK (kind IN ('postgresql','mysql','mariadb','redis','mongodb',
                                  'rabbitmq','kafka','elasticsearch','memcached','other')),
    name          TEXT    NOT NULL,                             -- display: "PostgreSQL 16"
    host          TEXT    NOT NULL DEFAULT '127.0.0.1',
    port          INTEGER NOT NULL,
    version       TEXT,
    runtime       TEXT    NOT NULL DEFAULT 'systemd'
                  CHECK (runtime IN ('systemd','docker','unknown')),
    systemd_unit  TEXT,                                         -- postgresql.service
    container_id  TEXT,                                         -- if runtime=docker
    status        TEXT    NOT NULL DEFAULT 'unknown'
                  CHECK (status IN ('active','inactive','unknown')),
    last_seen_at  TEXT,
    created_at    TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    UNIQUE (host, port)
);

------------------------------------------------------------------------------
-- project_dependencies: M-N edges, with evidence of how the link was found.
------------------------------------------------------------------------------
CREATE TABLE project_dependencies (
    project_id     INTEGER NOT NULL REFERENCES projects(id)     ON DELETE CASCADE,
    dependency_id  INTEGER NOT NULL REFERENCES dependencies(id) ON DELETE CASCADE,
    source         TEXT    NOT NULL DEFAULT 'env'
                   CHECK (source IN ('env','docker-network','manual','runtime-socket')),
    evidence       TEXT,                                        -- 'DATABASE_URL in .env.production'
    database_name  TEXT,                                        -- parsed from the URL when present
    confirmed      INTEGER NOT NULL DEFAULT 0 CHECK (confirmed IN (0,1)),  -- user-verified
    discovered_at  TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    PRIMARY KEY (project_id, dependency_id, source)
);

CREATE INDEX idx_projdep_dep ON project_dependencies(dependency_id);

------------------------------------------------------------------------------
-- deployment_history: one row per provisioning run / redeploy, with the full
-- step-machine record for auditing and resume.
------------------------------------------------------------------------------
CREATE TABLE deployment_history (
    id            INTEGER PRIMARY KEY,
    project_id    INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    kind          TEXT    NOT NULL DEFAULT 'deploy'
                  CHECK (kind IN ('provision','deploy','rollback','decommission')),
    git_ref       TEXT,                                         -- branch requested
    git_commit    TEXT,                                         -- resolved SHA actually deployed
    triggered_by  TEXT    NOT NULL DEFAULT 'ui',                -- ui | api | schedule | webhook
    status        TEXT    NOT NULL DEFAULT 'queued'
                  CHECK (status IN ('queued','running','succeeded','failed','rolled_back')),
    current_step  TEXT,                                         -- e.g. 'build'
    steps         TEXT    NOT NULL DEFAULT '[]',
                  -- JSON array: [{"name":"clone","status":"ok","started_at":...,
                  --               "finished_at":...,"log":"..."}, ...]
    error         TEXT,                                         -- failing step's message
    started_at    TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    finished_at   TEXT
);

CREATE INDEX idx_deploys_project ON deployment_history(project_id, started_at DESC);

------------------------------------------------------------------------------
-- resource_samples: rolling window of per-project cgroup metrics (pruned 24h).
------------------------------------------------------------------------------
CREATE TABLE resource_samples (
    project_id   INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    sampled_at   TEXT    NOT NULL,
    cpu_percent  REAL    NOT NULL,
    mem_bytes    INTEGER NOT NULL,
    disk_bytes   INTEGER,
    PRIMARY KEY (project_id, sampled_at)
) WITHOUT ROWID;

------------------------------------------------------------------------------
-- events: append-only feed backing the UI activity stream / WS replay.
------------------------------------------------------------------------------
CREATE TABLE events (
    id          INTEGER PRIMARY KEY,
    topic       TEXT NOT NULL,          -- 'deployment.step', 'topology.updated', 'unit.state'
    project_id  INTEGER REFERENCES projects(id) ON DELETE CASCADE,
    payload     TEXT NOT NULL DEFAULT '{}',
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

CREATE INDEX idx_events_created ON events(created_at DESC);

-- updated_at maintenance
CREATE TRIGGER trg_projects_touch AFTER UPDATE ON projects
BEGIN
    UPDATE projects SET updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
    WHERE id = NEW.id;
END;
