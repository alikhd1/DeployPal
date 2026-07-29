"""Background resource recorder: agent samples → resource_samples ring buffer.

The agent's StreamResources takes a fixed unit list, so the recorder re-opens
the stream every REFRESH seconds to pick up newly deployed / removed apps,
and prunes anything older than 24h while it's at it.
"""
import asyncio
from datetime import datetime, timezone

REFRESH = 60          # seconds per stream generation
RETRY = 15            # backoff when the agent is unreachable


async def record_resources(agent, db) -> None:
    while True:
        rows = await db.execute_fetchall(
            "SELECT id, systemd_unit FROM projects "
            "WHERE systemd_unit IS NOT NULL AND status = 'running'")
        unit_to_project = {r["systemd_unit"]: r["id"] for r in rows}
        if not unit_to_project:
            await asyncio.sleep(REFRESH)
            continue

        stream = agent.stream_resources(list(unit_to_project))
        try:
            async with asyncio.timeout(REFRESH):
                async for s in stream:
                    ts = datetime.fromtimestamp(s.ts, tz=timezone.utc).strftime(
                        "%Y-%m-%dT%H:%M:%SZ")
                    await db.execute(
                        """INSERT OR REPLACE INTO resource_samples
                               (project_id, sampled_at, cpu_percent, mem_bytes, disk_bytes)
                           VALUES (?, ?, ?, ?, ?)""",
                        (unit_to_project[s.unit], ts, s.cpu_pct,
                         s.mem_bytes, s.disk_bytes or None))
                await db.commit()  # stream ended by itself (agent shutdown)
        except TimeoutError:
            await db.commit()      # normal generation rollover
        except Exception:
            await asyncio.sleep(RETRY)   # agent down: back off, then retry
        finally:
            stream.cancel()

        await db.execute(
            "DELETE FROM resource_samples WHERE sampled_at < "
            "strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-1 day')")
        await db.commit()
