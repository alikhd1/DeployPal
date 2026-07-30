"""deploypal orchestrator — FastAPI application wiring.

Run:  uvicorn app.main:app --host 127.0.0.1 --port 8443
Config via env vars (see app/config.py): DEPLOYPAL_DB_PATH, DEPLOYPAL_AGENT_TARGET,
DEPLOYPAL_FRONTEND_DIST, DEPLOYPAL_CONTACT_EMAIL, DEPLOYPAL_DISCOVERY_INTERVAL.

Layout:
    app/
      main.py               ← this file: app factory, lifespan, static SPA mount
      config.py             ← env-driven settings
      db.py                 ← aiosqlite connection + schema bootstrap
      events.py             ← in-process pub/sub bus (+ events-table persistence)
      agent_client.py       ← async gRPC client over the agent UDS
      api/
        projects.py         ← registry CRUD, lifecycle actions, deploy trigger
        discovery.py        ← topology graph, dependency list, manual sweep
        logs.py             ← WS log relay + the shared /api/events feed
        system.py           ← host info, process table, resource WS
      services/
        discovery.py        ← the sweep: joins agent facts into the registry
        nginx_parser.py     ← server-block parsing (domains → upstream ports)
        stack_detect.py     ← project-type detection from directory contents
        env_deps.py         ← .env / docker-compose dependency resolution
        provisioner.py      ← clone→build→systemd→nginx→TLS step pipeline
        log_patterns.py     ← level classification + repetition collapsing
        resources.py        ← background recorder → resource_samples (24h)
"""
import asyncio
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles

from app import config, db, events
from app.agent_client import AgentClient
from app.api import discovery, logs, projects, services, system
from app.services.discovery import discovery_sweep
from app.services.resources import record_resources

settings = config.load()


@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.settings = settings
    app.state.db = await db.connect(settings.db_path, settings.schema_path)
    app.state.agent = AgentClient(settings.agent_target)
    app.state.bus = events.EventBus(app.state.db)

    async def periodic_discovery():
        while True:
            try:
                await discovery_sweep(app.state.agent, app.state.db, app.state.bus)
            except Exception as exc:  # a failed sweep must never kill the loop
                app.state.bus.emit("discovery.error", {"error": str(exc)})
            await asyncio.sleep(settings.discovery_interval)

    background = [
        asyncio.create_task(periodic_discovery()),
        asyncio.create_task(record_resources(app.state.agent, app.state.db)),
    ]
    yield
    for task in background:
        task.cancel()
    await app.state.agent.close()
    await app.state.db.close()


app = FastAPI(title="deploypal", lifespan=lifespan)
app.include_router(projects.router, prefix="/api/projects", tags=["projects"])
app.include_router(discovery.router, prefix="/api/topology", tags=["topology"])
app.include_router(logs.router, prefix="/api", tags=["streams"])
app.include_router(system.router, prefix="/api/system", tags=["system"])
app.include_router(services.router, prefix="/api/services", tags=["services"])


@app.get("/healthz")
async def healthz():
    return {"status": "ok"}


class SPAStaticFiles(StaticFiles):
    """Serve the built SPA; unknown paths fall back to index.html so
    client-side routes (/projects/3) survive a hard refresh."""

    async def get_response(self, path: str, scope):
        from starlette.exceptions import HTTPException as StarletteHTTPException
        try:
            response = await super().get_response(path, scope)
        except StarletteHTTPException as exc:
            if exc.status_code != 404:
                raise
            return await super().get_response("index.html", scope)
        if response.status_code == 404:
            return await super().get_response("index.html", scope)
        return response


# Built React bundle; skipped when no build exists (dev/API-only).
if Path(settings.frontend_dist).is_dir():
    app.mount("/", SPAStaticFiles(directory=settings.frontend_dist, html=True), name="spa")
