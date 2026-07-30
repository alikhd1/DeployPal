"""Service catalog endpoints: list recipes, install/remove, install history.

The catalog is owned by the agent (embedded in its binary + the root-owned
overlay dir) and queried live on every request — the orchestrator keeps no
copy, so an upgraded agent or a new overlay recipe is visible immediately.
"""
import asyncio
import json
import re

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, Field

from app.services.service_installer import run_service_install, take_secrets

router = APIRouter()

RECIPE_ID_RX = re.compile(r"^[a-z0-9][a-z0-9-]{1,40}$")
PARAM_VALUE_RX = re.compile(r"^[^\n\r\x00]{0,256}$")


class InstallBody(BaseModel):
    params: dict[str, str] = Field(default_factory=dict)


class RemoveBody(BaseModel):
    purge: bool = False
    force: bool = False   # required when projects still depend on the service


@router.get("")
async def catalog(request: Request):
    """Live recipe catalog merged with install history and registry links."""
    try:
        listing = await request.app.state.agent.list_service_recipes()
    except Exception as exc:
        raise HTTPException(502, f"agent unreachable: {exc}")

    db = request.app.state.db
    last_by_recipe = {r["recipe_id"]: dict(r) for r in await db.execute_fetchall(
        """SELECT recipe_id, id, action, status, error, started_at, finished_at
             FROM dependency_installs d1
            WHERE started_at = (SELECT MAX(started_at) FROM dependency_installs d2
                                 WHERE d2.recipe_id = d1.recipe_id)""")}
    deps_by_recipe = {r["recipe_id"]: dict(r) for r in await db.execute_fetchall(
        "SELECT id, recipe_id, port, status FROM dependencies "
        "WHERE origin='installed' AND recipe_id IS NOT NULL")}

    recipes = []
    for r in listing.recipes:
        recipes.append({
            "id": r.id, "kind": r.kind, "name": r.name, "description": r.description,
            "unit": r.unit, "default_port": r.default_port,
            "packages": list(r.packages), "source": r.source,
            "installed": r.installed, "installed_version": r.installed_version,
            "config_path": r.config_path,
            "params": [{
                "name": p.name, "type": p.type, "default": p.default,
                "values": list(p.values), "min": p.min, "max": p.max,
                "required": p.required, "advanced": p.advanced,
                "derived_hint": p.derived_hint, "unit_suffix": p.unit_suffix,
            } for p in r.params],
            "last_install": last_by_recipe.get(r.id),
            "dependency": deps_by_recipe.get(r.id),
        })
    return {"catalog_version": listing.catalog_version, "recipes": recipes}


@router.post("/{recipe_id}/install", status_code=202)
async def install(recipe_id: str, body: InstallBody, request: Request):
    recipe = await _get_recipe(request, recipe_id)
    for name, value in body.params.items():
        if not RECIPE_ID_RX.match(name.replace("_", "-")) or not PARAM_VALUE_RX.match(value):
            raise HTTPException(400, f"invalid param {name!r}")
    return await _launch(request, recipe, action="install", params=body.params)


@router.post("/{recipe_id}/remove", status_code=202)
async def remove(recipe_id: str, body: RemoveBody, request: Request):
    recipe = await _get_recipe(request, recipe_id)
    if not recipe["installed"]:
        raise HTTPException(409, f"{recipe_id} is not installed")

    db = request.app.state.db
    consumers = await db.execute_fetchall(
        """SELECT p.alias FROM project_dependencies pd
             JOIN projects p ON p.id = pd.project_id
             JOIN dependencies d ON d.id = pd.dependency_id
            WHERE d.recipe_id = ? AND d.origin = 'installed'""", (recipe_id,))
    if consumers and not body.force:
        raise HTTPException(
            409, "projects still depend on this service: "
                 + ", ".join(sorted(c["alias"] for c in consumers))
                 + " — pass force=true to remove anyway")
    return await _launch(request, recipe, action="remove", purge=body.purge)


@router.get("/installs")
async def installs(request: Request, limit: int = 50):
    rows = await request.app.state.db.execute_fetchall(
        "SELECT * FROM dependency_installs ORDER BY started_at DESC LIMIT ?",
        (min(max(limit, 1), 200),))
    return [dict(r) for r in rows]


@router.get("/installs/{install_id}")
async def install_detail(install_id: int, request: Request):
    rows = await request.app.state.db.execute_fetchall(
        "SELECT * FROM dependency_installs WHERE id=?", (install_id,))
    if not rows:
        raise HTTPException(404, "install not found")
    return dict(rows[0])


@router.get("/installs/{install_id}/secrets")
async def install_secrets(install_id: int, request: Request):
    """One-time reveal of secrets generated during an install. After this
    call they exist only in /etc/deploypal/secrets/ (root-only) on the host."""
    secrets = take_secrets(install_id)
    if secrets is None:
        raise HTTPException(404, "no unread secrets for this install")
    return {"secrets": secrets}


# ---------------------------------------------------------------- helpers

async def _get_recipe(request: Request, recipe_id: str) -> dict:
    if not RECIPE_ID_RX.match(recipe_id):
        raise HTTPException(400, "invalid recipe id")
    try:
        listing = await request.app.state.agent.list_service_recipes()
    except Exception as exc:
        raise HTTPException(502, f"agent unreachable: {exc}")
    for r in listing.recipes:
        if r.id == recipe_id:
            return {"id": r.id, "kind": r.kind, "name": r.name,
                    "installed": r.installed, "catalog_version": listing.catalog_version,
                    "secret_params": [p.name for p in r.params if p.type == "secret"]}
    raise HTTPException(404, f"no recipe {recipe_id!r} in the catalog")


async def _launch(request: Request, recipe: dict, *, action: str,
                  params: dict[str, str] | None = None, purge: bool = False):
    db, agent, bus = (request.app.state.db, request.app.state.agent,
                      request.app.state.bus)
    running = await db.execute_fetchall(
        "SELECT id, recipe_id FROM dependency_installs WHERE status IN ('queued','running')")
    if running:
        raise HTTPException(
            409, f"another package operation is running (install #{running[0]['id']}, "
                 f"{running[0]['recipe_id']}) — apt allows one transaction at a time")

    # Secret param values never reach SQLite — the record keeps a placeholder.
    stored = {k: ("***" if k in recipe.get("secret_params", ()) else v)
              for k, v in (params or {}).items()}
    cur = await db.execute(
        """INSERT INTO dependency_installs (recipe_id, action, params, catalog_version, status)
           VALUES (?, ?, ?, ?, 'running')""",
        (recipe["id"], action, json.dumps(stored), recipe["catalog_version"]))
    install_id = cur.lastrowid
    await db.commit()

    asyncio.create_task(run_service_install(
        agent, db, bus, install_id=install_id, recipe=recipe,
        params=params or {}, action=action, purge=purge))
    return {"install_id": install_id}
