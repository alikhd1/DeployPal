"""Provisioning pipeline: clone → build → systemd → nginx → TLS → health.

A deployment is a linear list of Steps. Each step records its outcome into
deployment_history.steps (JSON) and emits a WebSocket event, so the wizard
shows live progress. On failure, completed steps' `undo` callbacks run in
reverse order; the cloned tree is kept for debugging.

Builds run in-process as the unprivileged `smise` user (git/npm/pip/go are
ordinary subprocesses). Only steps 'systemd' onward touch the agent.
"""
import asyncio
import json
import shlex
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Awaitable, Callable

from jinja2 import Environment, FileSystemLoader

from app.agent_client import AgentClient, AgentError

APPS_ROOT = Path("/srv/apps")
PORT_RANGE = (3000, 3999)
_jinja = Environment(loader=FileSystemLoader("templates"), keep_trailing_newline=True)


@dataclass
class Ctx:
    """Everything a step may need; steps communicate by mutating this."""
    project_id: int
    deployment_id: int
    alias: str
    git_url: str
    branch: str
    domain: str
    port: int
    stack: str
    build_commands: list[str]
    start_command: str
    contact_email: str
    agent: AgentClient
    db: object
    bus: object
    root: Path = field(init=False)
    git_commit: str = ""

    def __post_init__(self):
        self.root = APPS_ROOT / self.alias

    @property
    def unit_name(self) -> str:
        return f"smise-app-{self.alias}.service"

    @property
    def site_filename(self) -> str:
        return f"{self.alias}.conf"


@dataclass
class Step:
    name: str
    run: Callable[[Ctx], Awaitable[str]]          # returns human-readable log
    undo: Callable[[Ctx], Awaitable[None]] | None = None


async def _sh(cwd: Path, command: str, timeout: int = 600) -> str:
    """Run one build command; captured output becomes the step log."""
    proc = await asyncio.create_subprocess_exec(
        *shlex.split(command), cwd=cwd,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
    )
    try:
        out, _ = await asyncio.wait_for(proc.communicate(), timeout)
    except asyncio.TimeoutError:
        proc.kill()
        raise RuntimeError(f"`{command}` timed out after {timeout}s")
    text = out.decode(errors="replace")
    if proc.returncode != 0:
        raise RuntimeError(f"`{command}` exited {proc.returncode}:\n{text[-4000:]}")
    return text[-4000:]


# ---------------------------------------------------------------- steps

async def step_clone(ctx: Ctx) -> str:
    ctx.root.parent.mkdir(parents=True, exist_ok=True)
    if (ctx.root / ".git").exists():                       # redeploy: fetch, don't reclone
        log = await _sh(ctx.root, f"git fetch origin {ctx.branch}")
        log += await _sh(ctx.root, f"git reset --hard origin/{ctx.branch}")
    else:
        log = await _sh(ctx.root.parent,
                        f"git clone --branch {ctx.branch} --depth 1 {shlex.quote(ctx.git_url)} {ctx.alias}")
    ctx.git_commit = (await _sh(ctx.root, "git rev-parse HEAD")).strip()
    return log


async def step_build(ctx: Ctx) -> str:
    logs = []
    for cmd in ctx.build_commands:
        logs.append(f"$ {cmd}\n" + await _sh(ctx.root, cmd))
    return "\n".join(logs) or "(no build steps)"


async def step_systemd(ctx: Ctx) -> str:
    unit = _jinja.get_template("systemd.service.j2").render(
        alias=ctx.alias, root=str(ctx.root), port=ctx.port,
        start_command=ctx.start_command.format(port=ctx.port),
        env_file=str(ctx.root / ".env") if (ctx.root / ".env").exists() else None,
    )
    await ctx.agent.install_unit(ctx.unit_name, unit, enable=True, start_now=True)
    return f"installed + started {ctx.unit_name}"

async def undo_systemd(ctx: Ctx) -> None:
    try:
        await ctx.agent.unit_action(ctx.unit_name, "stop")
    except AgentError:
        pass


async def step_nginx(ctx: Ctx) -> str:
    conf = _jinja.get_template("nginx-site.conf.j2").render(
        alias=ctx.alias, domain=ctx.domain, port=ctx.port,
        static_root=str(ctx.root) if ctx.stack == "static" else None,
    )
    await ctx.agent.write_nginx_site(ctx.site_filename, conf)
    await ctx.agent.enable_nginx_site(ctx.site_filename)
    await ctx.agent.test_nginx()          # raises with `nginx -t` output on failure
    await ctx.agent.reload_nginx()
    return f"enabled {ctx.site_filename} for {ctx.domain} → 127.0.0.1:{ctx.port}"


async def step_tls(ctx: Ctx) -> str:
    await ctx.agent.obtain_certificate([ctx.domain], ctx.contact_email)
    return f"certificate issued for {ctx.domain}"


async def step_health(ctx: Ctx) -> str:
    import httpx
    deadline = asyncio.get_event_loop().time() + 60
    last = "no response"
    async with httpx.AsyncClient() as client:
        while asyncio.get_event_loop().time() < deadline:
            try:
                r = await client.get(f"http://127.0.0.1:{ctx.port}/", timeout=3)
                if r.status_code < 500:
                    return f"healthy: HTTP {r.status_code}"
                last = f"HTTP {r.status_code}"
            except httpx.HTTPError as e:
                last = type(e).__name__
            await asyncio.sleep(2)
    raise RuntimeError(f"health check failed after 60s (last: {last})")


def build_pipeline(ctx: Ctx) -> list[Step]:
    steps = [
        Step("clone", step_clone),
        Step("build", step_build),
    ]
    if ctx.stack != "static":              # static sites need no process
        steps.append(Step("systemd", step_systemd, undo_systemd))
    steps += [
        Step("nginx", step_nginx),
        Step("tls", step_tls),
    ]
    if ctx.stack != "static":
        steps.append(Step("health", step_health))
    return steps


# ---------------------------------------------------------------- runner

async def run_deployment(ctx: Ctx) -> None:
    steps = build_pipeline(ctx)
    record: list[dict] = []
    done: list[Step] = []

    async def persist(status: str, error: str | None = None) -> None:
        await ctx.db.execute(
            "UPDATE deployment_history SET status=?, steps=?, error=?, git_commit=?, "
            "current_step=?, finished_at=CASE WHEN ? IN ('succeeded','failed') "
            "THEN strftime('%Y-%m-%dT%H:%M:%fZ','now') ELSE finished_at END WHERE id=?",
            (status, json.dumps(record), error, ctx.git_commit,
             record[-1]["name"] if record else None, status, ctx.deployment_id))
        await ctx.db.commit()

    await persist("running")
    for step in steps:
        entry = {"name": step.name, "status": "running",
                 "started_at": _now(), "finished_at": None, "log": ""}
        record.append(entry)
        await persist("running")
        ctx.bus.emit("deployment.step", {"deployment_id": ctx.deployment_id,
                                         "step": step.name, "status": "running"})
        try:
            entry["log"] = await step.run(ctx)
            entry["status"], entry["finished_at"] = "ok", _now()
            done.append(step)
        except Exception as exc:
            entry["status"], entry["finished_at"] = "failed", _now()
            entry["log"] += f"\n{exc}"
            for prior in reversed(done):
                if prior.undo:
                    try:
                        await prior.undo(ctx)
                    except Exception:
                        pass               # rollback is best-effort; record stands
            await persist("failed", error=f"{step.name}: {exc}")
            await ctx.db.execute("UPDATE projects SET status='failed' WHERE id=?",
                                 (ctx.project_id,))
            await ctx.db.commit()
            ctx.bus.emit("deployment.failed", {"deployment_id": ctx.deployment_id,
                                               "step": step.name, "error": str(exc)})
            return
        ctx.bus.emit("deployment.step", {"deployment_id": ctx.deployment_id,
                                         "step": step.name, "status": "ok"})

    await persist("succeeded")
    await ctx.db.execute(
        "UPDATE projects SET status='running', tls_enabled=1, systemd_unit=? WHERE id=?",
        (ctx.unit_name if ctx.stack != "static" else None, ctx.project_id))
    await ctx.db.commit()
    ctx.bus.emit("deployment.succeeded", {"deployment_id": ctx.deployment_id,
                                          "project_id": ctx.project_id})


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
