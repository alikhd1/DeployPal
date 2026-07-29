"""The discovery sweep: agent facts → registry upserts → topology events.

Read-only with respect to the system; idempotent with respect to the DB.
"""
from app.agent_client import AgentClient
from app.services import env_deps, nginx_parser

# Well-known dependency ports → kind (used when a listener matches).
KNOWN_DEP_PORTS = {5432: "postgresql", 3306: "mysql", 6379: "redis",
                   27017: "mongodb", 5672: "rabbitmq", 9092: "kafka",
                   9200: "elasticsearch", 11211: "memcached"}

APP_ROOTS = ("/srv/apps", "/var/www", "/opt")


async def discovery_sweep(agent: AgentClient, db, bus) -> None:
    sites = await agent.list_nginx_sites()
    ports = await agent.list_ports()
    units = await agent.list_units("*.service")

    # 1 ── infrastructure dependencies from listening ports
    unit_by_pid = {}  # not strictly needed; PortInfo already carries .unit
    for p in ports:
        kind = KNOWN_DEP_PORTS.get(p.port)
        if not kind or p.address not in ("127.0.0.1", "0.0.0.0", "::", "::1"):
            continue
        await db.execute(
            """INSERT INTO dependencies (kind, name, host, port, runtime,
                                         systemd_unit, status, last_seen_at)
               VALUES (?, ?, '127.0.0.1', ?, ?, ?, 'active',
                       strftime('%Y-%m-%dT%H:%M:%fZ','now'))
               ON CONFLICT(host, port) DO UPDATE SET
                   status='active', systemd_unit=excluded.systemd_unit,
                   last_seen_at=excluded.last_seen_at""",
            (kind, f"{kind} @ {p.port}", p.port,
             "systemd" if p.unit else "unknown", p.unit or None))

    # 2 ── nginx routes
    port_to_route_targets: dict[int, list] = {}
    for site in sites:
        for route in nginx_parser.parse_site(site.content):
            for name in route.server_names:
                await db.execute(
                    """INSERT INTO nginx_routes (server_name, listen_port,
                           location_path, upstream, upstream_port, config_file,
                           is_enabled, is_managed)
                       VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                       ON CONFLICT(server_name, listen_port, location_path)
                       DO UPDATE SET upstream=excluded.upstream,
                           upstream_port=excluded.upstream_port,
                           is_enabled=excluded.is_enabled,
                           discovered_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')""",
                    (name, route.listen_port, route.location, route.upstream,
                     route.upstream_port, site.path, int(site.enabled),
                     int(site.managed)))
            if route.upstream_port:
                port_to_route_targets.setdefault(route.upstream_port, [])

    # 3 ── unmanaged apps: a listener behind an nginx route whose cwd looks like
    #      an app tree and isn't registered yet → origin='discovered'
    known_dirs = {r["root_dir"] for r in await db.execute_fetchall(
        "SELECT root_dir FROM projects")}
    for p in ports:
        if p.port not in port_to_route_targets or p.pid < 0:
            continue
        # PortInfo carries unit; cwd comes from the process list on demand
        cwd = await _cwd_of(agent, p.pid)
        if not cwd or cwd in known_dirs or not cwd.startswith(APP_ROOTS):
            continue
        alias = cwd.rstrip("/").rsplit("/", 1)[-1].lower()[:40]
        await db.execute(
            """INSERT INTO projects (alias, origin, root_dir, stack, port,
                                     systemd_unit, status, last_seen_at)
               VALUES (?, 'discovered', ?, 'unknown', ?, ?, 'running',
                       strftime('%Y-%m-%dT%H:%M:%fZ','now'))
               ON CONFLICT(alias) DO UPDATE SET
                   last_seen_at=strftime('%Y-%m-%dT%H:%M:%fZ','now'),
                   status='running'""",
            (alias, cwd, p.port, p.unit or None))

    # 4 ── link routes to projects via upstream port
    await db.execute(
        """UPDATE nginx_routes SET project_id =
               (SELECT id FROM projects WHERE projects.port = nginx_routes.upstream_port)
           WHERE upstream_port IS NOT NULL""")

    # 5 ── per-project dependency resolution from env files
    for proj in await db.execute_fetchall(
            "SELECT id, root_dir FROM projects WHERE status != 'archived'"):
        for fname in env_deps.ENV_FILENAMES:
            raw = await agent.read_file(f"{proj['root_dir']}/{fname}")
            if raw is None:
                continue
            for ref in env_deps.resolve_deps(env_deps.parse_env(raw.decode(errors="replace")), fname):
                dep = await db.execute_fetchall(
                    "SELECT id FROM dependencies WHERE host=? AND port=?",
                    (ref.host, ref.port))
                if not dep:
                    continue        # references a service we can't see (remote?)
                await db.execute(
                    """INSERT INTO project_dependencies
                           (project_id, dependency_id, source, evidence, database_name)
                       VALUES (?, ?, 'env', ?, ?)
                       ON CONFLICT DO UPDATE SET evidence=excluded.evidence,
                           discovered_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')""",
                    (proj["id"], dep[0]["id"], ref.evidence, ref.database))

    await db.commit()
    bus.emit("topology.updated", {})


async def _cwd_of(agent: AgentClient, pid: int) -> str | None:
    raw = await agent.read_file(f"/proc/{pid}/cwd")  # agent resolves the symlink
    return raw.decode() if raw else None
