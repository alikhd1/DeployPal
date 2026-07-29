"""Registry + lifecycle + deployment endpoints."""
import asyncio
import re

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, Field, field_validator

from app.services import provisioner
from app.services.provisioner import Ctx, run_deployment

router = APIRouter()

ALIAS_RX = re.compile(r"^[a-z0-9][a-z0-9-]{1,39}$")
DOMAIN_RX = re.compile(r"^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$")


class NewProject(BaseModel):
    alias: str
    git_url: str                       # https://... or git@host:org/repo.git
    branch: str = "main"
    domain: str
    stack: str = Field("auto", pattern="^(auto|node|python|go|static)$")
    build_commands: list[str] | None = None    # override auto-detected
    start_command: str | None = None
    env_vars: dict[str, str] = {}

    @field_validator("alias")
    @classmethod
    def _alias(cls, v):
        if not ALIAS_RX.match(v):
            raise ValueError("alias must be lowercase [a-z0-9-], 2-40 chars")
        return v

    @field_validator("domain")
    @classmethod
    def _domain(cls, v):
        if not DOMAIN_RX.match(v):
            raise ValueError("invalid domain")
        return v

    @field_validator("git_url")
    @classmethod
    def _git(cls, v):
        if not (v.startswith("https://") or re.match(r"^[\w.-]+@[\w.-]+:", v)):
            raise ValueError("git_url must be https:// or ssh (user@host:path)")
        return v


@router.get("")
async def list_projects(request: Request):
    rows = await request.app.state.db.execute_fetchall(
        """SELECT p.*,
                  (SELECT status FROM deployment_history d
                    WHERE d.project_id = p.id ORDER BY d.started_at DESC LIMIT 1)
                    AS last_deploy_status
             FROM projects p WHERE p.status != 'archived' ORDER BY p.alias""")
    return [dict(r) for r in rows]


@router.post("", status_code=202)
async def create_project(body: NewProject, request: Request):
    db, agent, bus = (request.app.state.db, request.app.state.agent,
                      request.app.state.bus)

    # Stack detection happens before insert so the wizard can show a preview;
    # here we re-run it authoritatively if the user chose "auto".
    stack, build_cmds, start_cmd = body.stack, body.build_commands, body.start_command
    if stack == "auto":
        raise HTTPException(400, "resolve stack via POST /api/projects/detect first")
    if start_cmd is None and stack != "static":
        raise HTTPException(400, "start_command required for non-static stacks")

    # Reserve a port inside the same transaction as the project insert.
    reserved = [r["port"] for r in await db.execute_fetchall(
        "SELECT port FROM projects WHERE port IS NOT NULL")]
    try:
        port = await agent.find_free_port(*provisioner.PORT_RANGE, exclude=reserved)
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(502, f"port allocation failed (agent reachable?): {exc}")

    try:
        cur = await db.execute(
            """INSERT INTO projects (alias, origin, git_url, git_branch, root_dir,
                                     stack, port, start_command, domain, status)
               VALUES (?, 'provisioned', ?, ?, ?, ?, ?, ?, ?, 'provisioning')""",
            (body.alias, body.git_url, body.branch,
             str(provisioner.APPS_ROOT / body.alias), stack, port,
             start_cmd, body.domain))
        project_id = cur.lastrowid
        cur = await db.execute(
            """INSERT INTO deployment_history (project_id, kind, git_ref, status)
               VALUES (?, 'provision', ?, 'queued')""", (project_id, body.branch))
        deployment_id = cur.lastrowid
        await db.commit()
    except Exception as exc:
        if "UNIQUE" in str(exc):
            raise HTTPException(409, f"alias or domain already in use: {exc}")
        raise

    ctx = Ctx(project_id=project_id, deployment_id=deployment_id,
              alias=body.alias, git_url=body.git_url, branch=body.branch,
              domain=body.domain, port=port, stack=stack,
              build_commands=build_cmds or [], start_command=start_cmd or "",
              contact_email=request.app.state.settings.contact_email,
              agent=agent, db=db, bus=bus)
    asyncio.create_task(run_deployment(ctx))
    return {"project_id": project_id, "deployment_id": deployment_id, "port": port}


@router.post("/{project_id}/action")
async def project_action(project_id: int, body: dict, request: Request):
    action = body.get("action")
    if action not in ("start", "stop", "restart"):
        raise HTTPException(400, "action must be start|stop|restart")
    row = await _get(request, project_id)
    if not row["systemd_unit"]:
        raise HTTPException(409, "project has no managed systemd unit")
    await request.app.state.agent.unit_action(row["systemd_unit"], action)
    new_status = "stopped" if action == "stop" else "running"
    await request.app.state.db.execute(
        "UPDATE projects SET status=? WHERE id=?", (new_status, project_id))
    await request.app.state.db.commit()
    return {"status": new_status}


@router.post("/{project_id}/deploy", status_code=202)
async def redeploy(project_id: int, request: Request):
    """Pull latest on the configured branch and run the pipeline again."""
    row = await _get(request, project_id)
    db = request.app.state.db
    cur = await db.execute(
        """INSERT INTO deployment_history (project_id, kind, git_ref, status)
           VALUES (?, 'deploy', ?, 'queued')""", (project_id, row["git_branch"]))
    await db.commit()
    ctx = Ctx(project_id=project_id, deployment_id=cur.lastrowid,
              alias=row["alias"], git_url=row["git_url"], branch=row["git_branch"],
              domain=row["domain"], port=row["port"], stack=row["stack"],
              build_commands=[], start_command=row["start_command"] or "",
              contact_email=request.app.state.settings.contact_email,
              agent=request.app.state.agent, db=db, bus=request.app.state.bus)
    asyncio.create_task(run_deployment(ctx))
    return {"deployment_id": ctx.deployment_id}


@router.get("/{project_id}/resources")
async def resource_history(project_id: int, request: Request, minutes: int = 60):
    """Sampled CPU/RAM/disk for the sparkline charts (24h retention)."""
    minutes = max(1, min(minutes, 1440))
    rows = await request.app.state.db.execute_fetchall(
        """SELECT sampled_at, cpu_percent, mem_bytes, disk_bytes
             FROM resource_samples
            WHERE project_id = ?
              AND sampled_at >= strftime('%Y-%m-%dT%H:%M:%SZ', 'now', ?)
            ORDER BY sampled_at""",
        (project_id, f"-{minutes} minutes"))
    return [dict(r) for r in rows]


@router.get("/{project_id}/deployments")
async def deployments(project_id: int, request: Request):
    rows = await request.app.state.db.execute_fetchall(
        "SELECT * FROM deployment_history WHERE project_id=? "
        "ORDER BY started_at DESC LIMIT 50", (project_id,))
    return [dict(r) for r in rows]


async def _get(request: Request, project_id: int):
    rows = await request.app.state.db.execute_fetchall(
        "SELECT * FROM projects WHERE id=?", (project_id,))
    if not rows:
        raise HTTPException(404, "project not found")
    return rows[0]
