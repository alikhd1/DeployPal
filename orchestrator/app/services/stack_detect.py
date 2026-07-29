"""Application stack detection from directory contents.

Input is a directory listing (names only, fetched via agent ListDir) plus a
file-content getter for the handful of manifests we inspect. Returns the stack
plus enough detail to prefill build & start commands in the wizard.
"""
import json
from collections.abc import Awaitable, Callable
from dataclasses import dataclass

ReadFn = Callable[[str], Awaitable[bytes | None]]


@dataclass
class StackInfo:
    stack: str                  # node | python | go | static | docker | unknown
    detail: dict                # framework, entrypoint hints, ...
    build_commands: list[str]   # wizard defaults, user-editable
    start_command: str | None


async def detect_stack(root: str, names: set[str], read: ReadFn) -> StackInfo:
    if "docker-compose.yml" in names or "compose.yaml" in names or "Dockerfile" in names:
        return StackInfo("docker", {}, [], None)

    if "package.json" in names:
        pkg = {}
        if raw := await read(f"{root}/package.json"):
            try:
                pkg = json.loads(raw)
            except json.JSONDecodeError:
                pass
        scripts = pkg.get("scripts", {})
        deps = {**pkg.get("dependencies", {}), **pkg.get("devDependencies", {})}
        framework = next((f for f in ("next", "nuxt", "remix", "express", "fastify", "vite")
                          if f in deps), None)
        build = ["npm ci"] + (["npm run build"] if "build" in scripts else [])
        start = "npm run start" if "start" in scripts else f"node {pkg.get('main', 'index.js')}"
        return StackInfo("node", {"framework": framework}, build, start)

    if names & {"pyproject.toml", "requirements.txt", "Pipfile"}:
        detail: dict = {}
        for manifest in ("requirements.txt", "pyproject.toml"):
            if raw := await read(f"{root}/{manifest}"):
                text = raw.decode(errors="replace").lower()
                detail["framework"] = next(
                    (f for f in ("django", "fastapi", "flask") if f in text), None)
                break
        build = ["python3 -m venv .venv", ".venv/bin/pip install -r requirements.txt"
                 if "requirements.txt" in names else ".venv/bin/pip install ."]
        start = {
            "django":  ".venv/bin/gunicorn config.wsgi -b 127.0.0.1:{port}",
            "fastapi": ".venv/bin/uvicorn main:app --host 127.0.0.1 --port {port}",
            "flask":   ".venv/bin/gunicorn app:app -b 127.0.0.1:{port}",
        }.get(detail.get("framework"), ".venv/bin/python main.py")
        return StackInfo("python", detail, build, start)

    if "go.mod" in names:
        module = ""
        if raw := await read(f"{root}/go.mod"):
            first = raw.decode(errors="replace").splitlines()[0]
            module = first.removeprefix("module").strip()
        binary = module.rsplit("/", 1)[-1] or "app"
        return StackInfo("go", {"module": module},
                         [f"go build -o {binary} ."], f"./{binary}")

    if "index.html" in names or "dist" in names or "public" in names:
        return StackInfo("static", {}, [], None)   # served directly by nginx

    return StackInfo("unknown", {}, [], None)
