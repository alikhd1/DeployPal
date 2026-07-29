"""Nginx config parsing: raw site file → routes (server_name × location → upstream).

A tolerant single-purpose parser: it tokenizes block structure and extracts the
four directives we care about (listen, server_name, location, proxy_pass).
It deliberately does not try to be a full nginx grammar — for configs using
upstream{} blocks, the second pass resolves named upstreams to their first
server entry.
"""
import re
from dataclasses import dataclass, field

_COMMENT = re.compile(r"#.*$", re.MULTILINE)
_TOKEN = re.compile(r"\{|\}|;|[^{};\s]+")


@dataclass
class Route:
    server_names: list[str]
    listen_port: int
    tls: bool
    location: str
    upstream: str           # e.g. http://127.0.0.1:3007 (resolved)
    upstream_port: int | None


@dataclass
class _Block:
    name: str               # "server", "location /api", "upstream backend", ...
    directives: list[tuple[str, str]] = field(default_factory=list)
    children: list["_Block"] = field(default_factory=list)


def _parse_blocks(text: str) -> _Block:
    """Build the nesting tree from a config file body."""
    tokens = _TOKEN.findall(_COMMENT.sub("", text))
    root = _Block(name="<root>")
    stack = [root]
    pending: list[str] = []
    for tok in tokens:
        if tok == "{":
            block = _Block(name=" ".join(pending) or "<anon>")
            stack[-1].children.append(block)
            stack.append(block)
            pending = []
        elif tok == "}":
            if len(stack) > 1:
                stack.pop()
            pending = []
        elif tok == ";":
            if pending:
                stack[-1].directives.append((pending[0], " ".join(pending[1:])))
            pending = []
        else:
            pending.append(tok.strip())
    return root


_PORT_IN_URL = re.compile(r"^https?://(?P<host>[^:/]+)(?::(?P<port>\d+))?")


def parse_site(text: str) -> list[Route]:
    root = _parse_blocks(text)

    # Pass 1: named upstream{} blocks → first `server host:port` entry.
    upstreams: dict[str, str] = {}
    for block in root.children:
        if block.name.startswith("upstream "):
            name = block.name.split(None, 1)[1]
            for key, val in block.directives:
                if key == "server":
                    upstreams[name] = "http://" + val.split()[0]
                    break

    # Pass 2: server blocks.
    routes: list[Route] = []
    for server in (b for b in root.children if b.name == "server"):
        names: list[str] = []
        listen_port, tls = 80, False
        for key, val in server.directives:
            if key == "server_name":
                names = [n for n in val.split() if n != "_"]
            elif key == "listen":
                m = re.search(r"(\d+)", val.split()[0])
                if m:
                    listen_port = int(m.group(1))
                tls = tls or "ssl" in val

        def add(location: str, proxy_pass: str) -> None:
            target = proxy_pass
            m = _PORT_IN_URL.match(target)
            if m and m.group("host") in upstreams:      # http://backend_name/
                target = upstreams[m.group("host")]
                m = _PORT_IN_URL.match(target)
            port = int(m.group("port")) if (m and m.group("port")) else None
            routes.append(Route(names or ["<default>"], listen_port, tls,
                                location, target, port))

        # proxy_pass at server level (rare) and inside location blocks.
        for key, val in server.directives:
            if key == "proxy_pass":
                add("/", val)
        for loc in (c for c in server.children if c.name.startswith("location")):
            path = loc.name.split()[-1]
            for key, val in loc.directives:
                if key == "proxy_pass":
                    add(path, val)
    return routes
