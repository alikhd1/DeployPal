"""Log enrichment: level classification + repetition collapsing.

Each streamed line becomes a frame:
    {"ts": ..., "level": "error", "msg": ..., "fingerprint": "a3f...", "repeat": 1}

Repetition collapsing: volatile tokens (numbers, hex ids, uuids, ips, quoted
strings, durations) are masked out of the message; the masked template's hash
is the fingerprint. If the same fingerprint recurs within the window, we emit
a lightweight `repeat` update instead of a full frame — 500 identical
connection-timeout lines render as one row with ×500.
"""
import hashlib
import re
import time
from dataclasses import dataclass

# journald PRIORITY → level (syslog severities)
_PRIORITY_LEVEL = {0: "error", 1: "error", 2: "error", 3: "error",
                   4: "warn", 5: "info", 6: "info", 7: "debug"}

_LEVEL_RX = re.compile(
    r"\b(?P<err>ERROR|ERR|FATAL|CRITICAL|PANIC|Traceback|Exception)\b"
    r"|\b(?P<warn>WARN(?:ING)?)\b"
    r"|\b(?P<debug>DEBUG|TRACE)\b", re.IGNORECASE)

_MASKS = [
    (re.compile(r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b", re.I), "<uuid>"),
    (re.compile(r"\b\d{1,3}(?:\.\d{1,3}){3}(?::\d+)?\b"), "<ip>"),
    (re.compile(r"\b[0-9a-f]{7,40}\b", re.I), "<hex>"),
    (re.compile(r"\b\d+(?:\.\d+)?(?:ms|s|m|h|kb|mb|gb)?\b", re.I), "<n>"),
    (re.compile(r'"[^"]*"|\'[^\']*\''), "<str>"),
]


def classify_level(priority: int, message: str) -> str:
    """journald PRIORITY wins when the app sets it; else regex on the text."""
    if 0 <= priority <= 7:
        level = _PRIORITY_LEVEL[priority]
        if level != "info":          # apps logging to stdout often land at 6
            return level
    if m := _LEVEL_RX.search(message):
        if m.group("err"):
            return "error"
        if m.group("warn"):
            return "warn"
        if m.group("debug"):
            return "debug"
    return "info"


def fingerprint(message: str) -> str:
    masked = message
    for rx, token in _MASKS:
        masked = rx.sub(token, masked)
    return hashlib.blake2s(masked.encode(), digest_size=8).hexdigest()


@dataclass
class _Group:
    frame_id: int
    count: int
    last_seen: float


class Collapser:
    """Per-connection stream state. Returns what the WebSocket should send:
    ("frame", dict) for a new line, ("repeat", dict) for a collapsed one."""

    def __init__(self, window_seconds: float = 30.0):
        self.window = window_seconds
        self._groups: dict[str, _Group] = {}
        self._next_id = 0

    def ingest(self, ts_micros: int, priority: int, message: str):
        now = time.monotonic()
        fp = fingerprint(message)
        level = classify_level(priority, message)

        group = self._groups.get(fp)
        if group and now - group.last_seen <= self.window:
            group.count += 1
            group.last_seen = now
            return "repeat", {"frame_id": group.frame_id, "repeat": group.count,
                              "last_ts": ts_micros}

        self._next_id += 1
        self._groups[fp] = _Group(self._next_id, 1, now)
        if len(self._groups) > 2000:                      # bound memory
            cutoff = now - self.window
            self._groups = {k: g for k, g in self._groups.items()
                            if g.last_seen > cutoff}
        return "frame", {"frame_id": self._next_id, "ts": ts_micros,
                         "level": level, "msg": message, "fp": fp, "repeat": 1}
