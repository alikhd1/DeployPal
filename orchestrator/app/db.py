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
    return conn
