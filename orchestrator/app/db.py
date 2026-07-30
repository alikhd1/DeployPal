"""SQLite access: one aiosqlite connection, WAL mode, schema bootstrap.

aiosqlite serializes all statements onto a single worker thread, so sharing
one connection across tasks is safe. The orchestrator is the DB's only writer
(the agent never touches it), matching the single-writer design.
"""
from pathlib import Path

import aiosqlite


async def connect(db_path: str, schema_path: str) -> aiosqlite.Connection:
    Path(db_path).parent.mkdir(parents=True, exist_ok=True)
    conn = await aiosqlite.connect(db_path)
    conn.row_factory = aiosqlite.Row

    await conn.execute("PRAGMA journal_mode=WAL")
    await conn.execute("PRAGMA foreign_keys=ON")
    await conn.execute("PRAGMA busy_timeout=5000")

    existing = await conn.execute_fetchall(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='projects'")
    if not existing:
        await conn.executescript(Path(schema_path).read_text(encoding="utf-8"))
        await conn.commit()
    await _migrate(conn)
    return conn


async def _migrate(conn: aiosqlite.Connection) -> None:
    """Idempotent additive migrations for databases created before the
    service catalog existed. Fresh databases get everything from schema.sql,
    so each step first checks whether it already applies."""
    dep_cols = {r["name"] for r in await conn.execute_fetchall(
        "PRAGMA table_info(dependencies)")}
    if "origin" not in dep_cols:
        await conn.execute(
            "ALTER TABLE dependencies ADD COLUMN origin TEXT NOT NULL DEFAULT 'discovered' "
            "CHECK (origin IN ('discovered','installed'))")
        await conn.execute("ALTER TABLE dependencies ADD COLUMN recipe_id TEXT")
        await conn.execute("ALTER TABLE dependencies ADD COLUMN managed_config_path TEXT")
    await conn.execute("""
        CREATE TABLE IF NOT EXISTS dependency_installs (
            id              INTEGER PRIMARY KEY,
            recipe_id       TEXT    NOT NULL,
            action          TEXT    NOT NULL DEFAULT 'install'
                            CHECK (action IN ('install','remove')),
            dependency_id   INTEGER REFERENCES dependencies(id) ON DELETE SET NULL,
            params          TEXT    NOT NULL DEFAULT '{}',
            catalog_version TEXT,
            status          TEXT    NOT NULL DEFAULT 'queued'
                            CHECK (status IN ('queued','running','succeeded','failed')),
            current_step    TEXT,
            steps           TEXT    NOT NULL DEFAULT '[]',
            error           TEXT,
            started_at      TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
            finished_at     TEXT
        )""")
    await conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_dep_installs_recipe "
        "ON dependency_installs(recipe_id, started_at DESC)")
    await conn.commit()
