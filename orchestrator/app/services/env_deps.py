"""Dependency resolution from environment files.

Scans .env-style files for connection URLs and discrete host/port variable
groups, yielding (kind, host, port, database, evidence) tuples that the
discovery sweep matches against the `dependencies` table (which is itself
populated from listening-port facts: postgres on 5432, redis on 6379, ...).
"""
import re
from dataclasses import dataclass
from urllib.parse import urlparse

ENV_FILENAMES = (".env", ".env.production", ".env.local")

_SCHEME_KIND = {
    "postgres": "postgresql", "postgresql": "postgresql",
    "mysql": "mysql", "mariadb": "mariadb",
    "redis": "redis", "rediss": "redis",
    "mongodb": "mongodb", "mongodb+srv": "mongodb",
    "amqp": "rabbitmq", "amqps": "rabbitmq",
    "kafka": "kafka",
}
_DEFAULT_PORT = {"postgresql": 5432, "mysql": 3306, "mariadb": 3306,
                 "redis": 6379, "mongodb": 27017, "rabbitmq": 5672, "kafka": 9092}

_LINE = re.compile(r"""^\s*(?:export\s+)?(?P<key>[A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?P<val>.*)$""")
# Discrete variable groups: PGHOST/PGPORT, DB_HOST/DB_PORT, REDIS_HOST/...
_GROUPS = [
    ("postgresql", ("PGHOST", "POSTGRES_HOST", "DB_HOST", "DATABASE_HOST"),
                   ("PGPORT", "POSTGRES_PORT", "DB_PORT", "DATABASE_PORT")),
    ("redis",      ("REDIS_HOST",), ("REDIS_PORT",)),
    ("mysql",      ("MYSQL_HOST",), ("MYSQL_PORT",)),
    ("mongodb",    ("MONGO_HOST",), ("MONGO_PORT",)),
]


@dataclass(frozen=True)
class DepRef:
    kind: str
    host: str
    port: int
    database: str | None
    evidence: str           # "DATABASE_URL in .env.production"


def parse_env(text: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for line in text.splitlines():
        if line.lstrip().startswith("#"):
            continue
        if m := _LINE.match(line):
            out[m.group("key")] = m.group("val").strip().strip("'\"")
    return out


def resolve_deps(env: dict[str, str], filename: str) -> set[DepRef]:
    found: set[DepRef] = set()

    # 1. URL-style values, wherever they appear.
    for key, val in env.items():
        if "://" not in val:
            continue
        try:
            u = urlparse(val)
        except ValueError:
            continue
        kind = _SCHEME_KIND.get(u.scheme)
        if not kind:
            continue
        found.add(DepRef(
            kind=kind,
            host=u.hostname or "127.0.0.1",
            port=u.port or _DEFAULT_PORT[kind],
            database=(u.path or "/").lstrip("/") or None,
            evidence=f"{key} in {filename}",
        ))

    # 2. Discrete host/port variable groups.
    for kind, host_keys, port_keys in _GROUPS:
        host = next((env[k] for k in host_keys if k in env), None)
        if not host:
            continue
        port_raw = next((env[k] for k in port_keys if k in env), None)
        port = int(port_raw) if port_raw and port_raw.isdigit() else _DEFAULT_PORT[kind]
        used_key = next(k for k in host_keys if k in env)
        found.add(DepRef(kind, host, port, None, f"{used_key} in {filename}"))

    # Localhost aliases normalize to one host so DB matching works.
    return {
        DepRef(d.kind, "127.0.0.1" if d.host in ("localhost", "::1") else d.host,
               d.port, d.database, d.evidence)
        for d in found
    }
