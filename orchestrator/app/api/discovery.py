"""Topology endpoints: the graph the dashboard renders, the global dependency
list, and on-demand sweeps."""
from fastapi import APIRouter, HTTPException, Request

from app.services.discovery import discovery_sweep

router = APIRouter()


@router.get("")
async def topology_graph(request: Request):
    """Nodes + edges for React Flow: domains → projects → dependencies."""
    db = request.app.state.db
    projects = await db.execute_fetchall(
        "SELECT id, alias, stack, status, port, origin FROM projects "
        "WHERE status != 'archived'")
    routes = await db.execute_fetchall(
        "SELECT server_name, project_id, upstream_port, is_enabled "
        "FROM nginx_routes WHERE project_id IS NOT NULL")
    deps = await db.execute_fetchall(
        "SELECT id, kind, name, port, status FROM dependencies")
    links = await db.execute_fetchall(
        "SELECT project_id, dependency_id, source, database_name "
        "FROM project_dependencies")

    nodes, edges = [], []
    for d in {r["server_name"]: r for r in routes}.values():
        nodes.append({"id": f"domain:{d['server_name']}", "type": "domain",
                      "label": d["server_name"], "enabled": bool(d["is_enabled"])})
    for p in projects:
        nodes.append({"id": f"project:{p['id']}", "type": "project",
                      "label": p["alias"], "stack": p["stack"],
                      "status": p["status"], "origin": p["origin"]})
    for d in deps:
        nodes.append({"id": f"dep:{d['id']}", "type": "dependency",
                      "label": d["name"], "kind": d["kind"], "status": d["status"]})
    for r in routes:
        edges.append({"source": f"domain:{r['server_name']}",
                      "target": f"project:{r['project_id']}",
                      "label": f":{r['upstream_port']}"})
    for l in links:
        edges.append({"source": f"project:{l['project_id']}",
                      "target": f"dep:{l['dependency_id']}",
                      "label": l["database_name"] or l["source"]})
    return {"nodes": nodes, "edges": edges}


@router.get("/dependencies")
async def dependency_list(request: Request):
    """Global list: every infra service and which projects are connected."""
    db = request.app.state.db
    deps = await db.execute_fetchall("SELECT * FROM dependencies ORDER BY kind, port")
    out = []
    for d in deps:
        consumers = await db.execute_fetchall(
            """SELECT p.id, p.alias, pd.source, pd.evidence, pd.database_name
                 FROM project_dependencies pd JOIN projects p ON p.id = pd.project_id
                WHERE pd.dependency_id = ? ORDER BY p.alias""", (d["id"],))
        out.append({**dict(d), "consumers": [dict(c) for c in consumers]})
    return out


@router.post("/sweep", status_code=202)
async def sweep_now(request: Request):
    """Run a discovery sweep immediately (UI refresh button)."""
    try:
        await discovery_sweep(request.app.state.agent, request.app.state.db,
                              request.app.state.bus)
    except Exception as exc:
        raise HTTPException(502, f"sweep failed (agent reachable?): {exc}")
    return {"status": "completed"}
