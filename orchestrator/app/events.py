"""In-process event bus.

`emit` is synchronous and non-blocking so services can fire events from
anywhere inside the loop: subscribers get the event via per-connection queues
(slow consumers drop rather than block the emitter), and each event is also
persisted to the `events` table as a best-effort background task, backing the
UI activity feed and post-hoc debugging.
"""
import asyncio
import json
import time


class EventBus:
    def __init__(self, db=None):
        self._db = db
        self._subs: set[asyncio.Queue] = set()

    def subscribe(self, max_queue: int = 1000) -> asyncio.Queue:
        q: asyncio.Queue = asyncio.Queue(maxsize=max_queue)
        self._subs.add(q)
        return q

    def unsubscribe(self, q: asyncio.Queue) -> None:
        self._subs.discard(q)

    def emit(self, topic: str, payload: dict, project_id: int | None = None) -> None:
        event = {"topic": topic, "project_id": project_id,
                 "payload": payload, "ts": time.time()}
        for q in list(self._subs):
            try:
                q.put_nowait(event)
            except asyncio.QueueFull:
                pass  # slow consumer: drop for them, never block the emitter
        if self._db is not None:
            asyncio.create_task(self._persist(event))

    async def _persist(self, event: dict) -> None:
        try:
            await self._db.execute(
                "INSERT INTO events (topic, project_id, payload) VALUES (?, ?, ?)",
                (event["topic"], event["project_id"], json.dumps(event["payload"])))
            await self._db.commit()
        except Exception:
            pass  # the feed must never take the app down (e.g. during shutdown)
