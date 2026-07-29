"""Runtime configuration — env-var driven with production defaults.

Everything the orchestrator touches outside its own code is configurable, so
dev boxes and tests can boot without a real agent, /var/lib, or a built SPA.
"""
import os
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent


@dataclass(frozen=True)
class Settings:
    db_path: str
    schema_path: str
    agent_target: str
    frontend_dist: str
    contact_email: str
    discovery_interval: int


def load() -> Settings:
    return Settings(
        db_path=os.environ.get("DEPLOYPAL_DB_PATH", "/var/lib/deploypal/state.db"),
        schema_path=os.environ.get("DEPLOYPAL_SCHEMA_PATH",
                                   str(REPO_ROOT / "db" / "schema.sql")),
        agent_target=os.environ.get("DEPLOYPAL_AGENT_TARGET",
                                    "unix:///run/deploypal/agent.sock"),
        frontend_dist=os.environ.get("DEPLOYPAL_FRONTEND_DIST",
                                     str(REPO_ROOT / "frontend" / "dist")),
        contact_email=os.environ.get("DEPLOYPAL_CONTACT_EMAIL", "admin@localhost"),
        discovery_interval=int(os.environ.get("DEPLOYPAL_DISCOVERY_INTERVAL", "60")),
    )
