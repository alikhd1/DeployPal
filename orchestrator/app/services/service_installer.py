"""Service-catalog install/remove runner.

Mirrors the provisioner's recorded-pipeline shape: the agent streams
InstallProgress chunks, this module folds them into a step list persisted in
dependency_installs (live UI via WebSocket events), and on success registers
the service in the dependencies registry.

Secrets discipline: generated secrets arrive once on the final stream message.
They are parked in an in-memory one-time store for a single UI reveal and are
never written to SQLite or the event bus — the durable copy lives root-only at
/etc/deploypal/secrets/ on the host.
"""
import json
from datetime import datetime, timezone

# Recipe kinds that belong in the dependencies registry (must stay a subset of
# the dependencies.kind CHECK constraint). Plain tools are tracked only in
# dependency_installs + live dpkg state.
DEPENDENCY_KINDS = {"postgresql", "mysql", "mariadb", "redis", "mongodb",
                    "rabbitmq", "kafka", "elasticsearch", "memcached"}

# install_id -> secrets dict; popped on first read.
_pending_secrets: dict[int, dict[str, str]] = {}


def take_secrets(install_id: int) -> dict[str, str] | None:
    return _pending_secrets.pop(install_id, None)


async def run_service_install(agent, db, bus, *, install_id: int, recipe: dict,
                              params: dict[str, str], action: str = "install",
                              purge: bool = False) -> None:
    steps: list[dict] = []
    by_name: dict[str, dict] = {}

    async def persist(status: str, error: str | None = None) -> None:
        await db.execute(
            "UPDATE dependency_installs SET status=?, steps=?, error=?, current_step=?, "
            "finished_at=CASE WHEN ? IN ('succeeded','failed') "
            "THEN strftime('%Y-%m-%dT%H:%M:%fZ','now') ELSE finished_at END WHERE id=?",
            (status, json.dumps(steps), error,
             steps[-1]["name"] if steps else None, status, install_id))
        await db.commit()

    def fold(chunk) -> None:
        """One progress chunk → the step record (append log / set status)."""
        entry = by_name.get(chunk.step)
        if entry is None:
            entry = {"name": chunk.step, "status": "running",
                     "started_at": _now(), "finished_at": None, "log": ""}
            by_name[chunk.step] = entry
            steps.append(entry)
        if chunk.log:
            entry["log"] = (entry["log"] + "\n" + chunk.log).strip()[-16000:]
        if chunk.status in ("ok", "failed") and entry["status"] == "running":
            entry["status"] = chunk.status
            entry["finished_at"] = _now()

    await persist("running")
    bus.emit("service.install.step",
             {"install_id": install_id, "recipe_id": recipe["id"],
              "action": action, "step": "start", "status": "running"})

    final = None
    try:
        stream = (agent.remove_service(recipe["id"], purge) if action == "remove"
                  else agent.install_service(recipe["id"], params))
        last_emitted = None
        async for chunk in stream:
            if chunk.done:
                final = chunk
                break
            fold(chunk)
            # Persist + notify on step transitions; plain log chunks only persist.
            key = (chunk.step, chunk.status)
            if key != last_emitted:
                last_emitted = key
                bus.emit("service.install.step",
                         {"install_id": install_id, "recipe_id": recipe["id"],
                          "action": action, "step": chunk.step, "status": chunk.status})
            await persist("running")
    except Exception as exc:
        await persist("failed", error=str(exc))
        bus.emit("service.install.finished",
                 {"install_id": install_id, "recipe_id": recipe["id"],
                  "action": action, "ok": False, "error": str(exc)})
        return

    if final is None or not final.ok:
        error = (final.log if final is not None else "") or "stream ended unexpectedly"
        await persist("failed", error=error)
        bus.emit("service.install.finished",
                 {"install_id": install_id, "recipe_id": recipe["id"],
                  "action": action, "ok": False, "error": error})
        return

    facts = dict(final.facts)
    if action == "install":
        dep_id = await _register_dependency(db, recipe, facts)
        if dep_id is not None:
            await db.execute("UPDATE dependency_installs SET dependency_id=? WHERE id=?",
                             (dep_id, install_id))
        if final.secrets:
            _pending_secrets[install_id] = dict(final.secrets)
    else:
        await db.execute(
            "UPDATE dependencies SET status='inactive' WHERE recipe_id=? AND origin='installed'",
            (recipe["id"],))

    await persist("succeeded")
    bus.emit("service.install.finished",
             {"install_id": install_id, "recipe_id": recipe["id"], "action": action,
              "ok": True, "facts": facts,
              "has_secrets": bool(final.secrets)})


async def _register_dependency(db, recipe: dict, facts: dict) -> int | None:
    """Upsert the installed service into the dependencies registry so it shows
    up in topology immediately (the next discovery sweep would find it too —
    this just removes the latency)."""
    if recipe["kind"] not in DEPENDENCY_KINDS or not facts.get("port"):
        return None
    version = facts.get("version", "")
    await db.execute(
        """INSERT INTO dependencies (kind, name, host, port, version, runtime,
                                     systemd_unit, status, origin, recipe_id,
                                     managed_config_path, last_seen_at)
           VALUES (?, ?, '127.0.0.1', ?, ?, 'systemd', ?, 'active', 'installed', ?, ?,
                   strftime('%Y-%m-%dT%H:%M:%fZ','now'))
           ON CONFLICT(host, port) DO UPDATE SET
               kind=excluded.kind, name=excluded.name, version=excluded.version,
               systemd_unit=excluded.systemd_unit, status='active',
               origin='installed', recipe_id=excluded.recipe_id,
               managed_config_path=excluded.managed_config_path,
               last_seen_at=excluded.last_seen_at""",
        (recipe["kind"], f"{recipe['name']} {version}".strip(), int(facts["port"]),
         version or None, facts.get("unit") or None, recipe["id"],
         facts.get("config_path") or None))
    await db.commit()
    rows = await db.execute_fetchall(
        "SELECT id FROM dependencies WHERE host='127.0.0.1' AND port=?",
        (int(facts["port"]),))
    return rows[0]["id"] if rows else None


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
