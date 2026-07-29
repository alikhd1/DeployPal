"""Host-level endpoints: system info, process table, live resource stream."""
import json

from fastapi import APIRouter, HTTPException, Request, WebSocket, WebSocketDisconnect

router = APIRouter()


@router.get("")
async def system_info(request: Request):
    try:
        info = await request.app.state.agent.get_system_info()
    except Exception as exc:
        raise HTTPException(502, f"agent unreachable: {exc}")
    return {"hostname": info.hostname, "kernel": info.kernel, "distro": info.distro,
            "mem_total": info.mem_total, "cpu_count": info.cpu_count,
            "load1": info.load1, "disk_total": info.disk_total,
            "disk_free": info.disk_free, "agent_version": info.agent_version}


@router.get("/processes")
async def processes(request: Request, limit: int = 50):
    """Top processes by CPU (the dashboard's host process table)."""
    try:
        procs = await request.app.state.agent.list_processes()
    except Exception as exc:
        raise HTTPException(502, f"agent unreachable: {exc}")
    top = sorted(procs, key=lambda p: p.cpu_pct, reverse=True)[:min(limit, 200)]
    return [{"pid": p.pid, "comm": p.comm, "cmdline": p.cmdline, "unit": p.unit,
             "cwd": p.cwd, "rss": p.rss, "cpu_pct": round(p.cpu_pct, 1)}
            for p in top]


@router.websocket("/resources")
async def resource_stream(ws: WebSocket):
    """Live cgroup samples for the units in ?units=a.service,b.service."""
    await ws.accept()
    units = [u for u in ws.query_params.get("units", "").split(",") if u]
    if not units:
        await ws.close(code=4400, reason="units query param required")
        return
    stream = ws.app.state.agent.stream_resources(units)
    try:
        async for sample in stream:
            await ws.send_text(json.dumps({
                "unit": sample.unit, "ts": sample.ts,
                "cpu_pct": round(sample.cpu_pct, 1),
                "mem_bytes": sample.mem_bytes, "disk_bytes": sample.disk_bytes}))
    except WebSocketDisconnect:
        pass
    except Exception as exc:
        try:
            await ws.send_text(json.dumps({"error": str(exc)}))
        except Exception:
            pass
    finally:
        stream.cancel()
