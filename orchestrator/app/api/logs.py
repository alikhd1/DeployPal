"""WebSocket log relay: agent gRPC stream → enrichment → browser.

Backpressure policy: if the browser can't keep up, we keep every error/warn
frame and sample info/debug rather than buffering unboundedly.
"""
import asyncio
import json

from fastapi import APIRouter, Request, WebSocket, WebSocketDisconnect

from app.services.log_patterns import Collapser

router = APIRouter()

QUEUE_HIGH_WATER = 500


@router.get("/events/recent")
async def recent_events(request: Request, limit: int = 50):
    """Historical feed backing the dashboard activity list."""
    rows = await request.app.state.db.execute_fetchall(
        "SELECT id, topic, project_id, payload, created_at FROM events "
        "ORDER BY id DESC LIMIT ?", (min(limit, 200),))
    return [{"id": r["id"], "topic": r["topic"], "project_id": r["project_id"],
             "payload": json.loads(r["payload"]), "created_at": r["created_at"]}
            for r in rows]


@router.websocket("/events")
async def event_feed(ws: WebSocket):
    """The shared event feed: deployment steps, topology updates, unit state.
    Clients filter by topic; optional ?topics=a,b narrows at the server."""
    await ws.accept()
    topics = {t for t in ws.query_params.get("topics", "").split(",") if t}
    bus = ws.app.state.bus
    queue = bus.subscribe()
    try:
        while True:
            event = await queue.get()
            if topics and event["topic"] not in topics:
                continue
            await ws.send_text(json.dumps(event))
    except WebSocketDisconnect:
        pass
    finally:
        bus.unsubscribe(queue)


@router.websocket("/projects/{project_id}/logs")
async def project_logs(ws: WebSocket, project_id: int):
    await ws.accept()
    app = ws.app
    rows = await app.state.db.execute_fetchall(
        "SELECT systemd_unit FROM projects WHERE id=?", (project_id,))
    if not rows or not rows[0]["systemd_unit"]:
        await ws.close(code=4404, reason="no unit for project")
        return
    unit = rows[0]["systemd_unit"]

    params = ws.query_params
    cursor = params.get("cursor", "")
    tail = min(int(params.get("tail", "200")), 2000)

    collapser = Collapser()
    queue: asyncio.Queue = asyncio.Queue()

    async def pump_agent():
        """gRPC stream → queue, applying the sampling policy under pressure."""
        try:
            async for line in app.state.agent.stream_logs(unit, tail=tail, cursor=cursor):
                kind, payload = collapser.ingest(line.ts_micros, line.priority,
                                                 line.message)
                if queue.qsize() > QUEUE_HIGH_WATER:
                    if kind == "repeat" or payload.get("level") in ("info", "debug"):
                        continue                      # shed load, keep errors
                payload["cursor"] = line.cursor       # client resumes from here
                await queue.put((kind, payload))
        except Exception as exc:
            await queue.put(("error", {"msg": f"log stream ended: {exc}"}))

    pump = asyncio.create_task(pump_agent())
    try:
        while True:
            kind, payload = await queue.get()
            await ws.send_text(json.dumps({"type": kind, **payload}))
            if kind == "error":
                break
    except WebSocketDisconnect:
        pass
    finally:
        pump.cancel()
