"""Async gRPC client for deploypal-agent over the Unix domain socket.

Generated stubs come from scripts/gen-protos.ps1 (or .sh):
    python -m grpc_tools.protoc -I proto \
        --python_out=orchestrator/gen --grpc_python_out=orchestrator/gen \
        --pyi_out=orchestrator/gen proto/deploypal/agent/v1/agent.proto

grpc_tools emits absolute imports (`from deploypal.agent.v1 import ...`), so the
gen/ directory itself must be importable — added to sys.path here, once.
"""
import sys
from collections.abc import AsyncIterator
from pathlib import Path

_GEN_DIR = str(Path(__file__).resolve().parent.parent / "gen")
if _GEN_DIR not in sys.path:
    sys.path.insert(0, _GEN_DIR)

import grpc

from deploypal.agent.v1 import agent_pb2 as pb
from deploypal.agent.v1 import agent_pb2_grpc as rpc


class AgentError(RuntimeError):
    """A mutating agent operation reported failure; .detail carries its output."""

    def __init__(self, op: str, detail: str):
        super().__init__(f"{op}: {detail}")
        self.op, self.detail = op, detail


class AgentClient:
    def __init__(self, target: str = "unix:///run/deploypal/agent.sock"):
        self._channel = grpc.aio.insecure_channel(target)
        self._stub = rpc.AgentStub(self._channel)

    async def close(self) -> None:
        await self._channel.close()

    # ---- discovery ----
    async def get_system_info(self) -> pb.SystemInfo:
        return await self._stub.GetSystemInfo(pb.Empty())

    async def list_processes(self) -> list[pb.ProcessInfo]:
        return list((await self._stub.ListProcesses(pb.Empty())).processes)

    async def list_nginx_sites(self) -> list[pb.NginxSite]:
        return list((await self._stub.ListNginxSites(pb.Empty())).sites)

    async def list_ports(self) -> list[pb.PortInfo]:
        return list((await self._stub.ListListeningPorts(pb.Empty())).ports)

    async def list_units(self, pattern: str = "*.service") -> list[pb.UnitInfo]:
        return list((await self._stub.ListUnits(pb.ListUnitsRequest(pattern=pattern))).units)

    async def read_file(self, path: str, max_bytes: int = 256_000) -> bytes | None:
        try:
            resp = await self._stub.ReadFile(pb.ReadFileRequest(path=path, max_bytes=max_bytes))
            return resp.content
        except grpc.aio.AioRpcError as e:
            if e.code() == grpc.StatusCode.NOT_FOUND:
                return None
            raise

    # ---- provisioning ----
    async def find_free_port(self, start: int, end: int, exclude: list[int]) -> int:
        resp = await self._stub.FindFreePort(
            pb.FindFreePortRequest(range_start=start, range_end=end, exclude=exclude)
        )
        return resp.port

    async def install_unit(self, name: str, content: str, *, enable=True, start_now=True):
        self._check(await self._stub.InstallUnit(pb.InstallUnitRequest(
            name=name, content=content, enable=enable, start_now=start_now)), "install_unit")

    async def unit_action(self, name: str, action: str):
        self._check(await self._stub.UnitAction(
            pb.UnitActionRequest(name=name, action=action)), f"{action} {name}")

    async def write_nginx_site(self, filename: str, content: str):
        self._check(await self._stub.WriteNginxSite(
            pb.WriteNginxSiteRequest(filename=filename, content=content)), "write_nginx_site")

    async def enable_nginx_site(self, filename: str):
        self._check(await self._stub.EnableNginxSite(
            pb.NginxSiteRef(filename=filename)), "enable_nginx_site")

    async def test_nginx(self):
        self._check(await self._stub.TestNginxConfig(pb.Empty()), "nginx -t")

    async def reload_nginx(self):
        self._check(await self._stub.ReloadNginx(pb.Empty()), "nginx reload")

    async def obtain_certificate(self, domains: list[str], email: str):
        self._check(await self._stub.ObtainCertificate(
            pb.CertRequest(domains=domains, contact_email=email)), "certbot")

    # ---- service catalog ----
    async def list_service_recipes(self) -> pb.RecipeList:
        """The agent owns the catalog (embedded + overlay) — never cache this;
        it changes when DeployPal is upgraded or an overlay recipe is added."""
        return await self._stub.ListServiceRecipes(pb.Empty())

    def install_service(self, recipe_id: str,
                        params: dict[str, str]) -> AsyncIterator[pb.InstallProgress]:
        return self._stub.InstallService(pb.InstallServiceRequest(
            recipe_id=recipe_id, params=params))

    def remove_service(self, recipe_id: str,
                       purge: bool = False) -> AsyncIterator[pb.InstallProgress]:
        return self._stub.RemoveService(pb.RemoveServiceRequest(
            recipe_id=recipe_id, purge=purge))

    # ---- streaming ----
    def stream_logs(self, unit: str, *, tail: int = 200,
                    cursor: str = "") -> AsyncIterator[pb.LogLine]:
        return self._stub.StreamLogs(pb.LogStreamRequest(
            unit=unit, tail_lines=tail, follow=True, cursor=cursor))

    def stream_resources(self, units: list[str], interval: int = 5) -> AsyncIterator[pb.ResourceSample]:
        return self._stub.StreamResources(pb.ResourceStreamRequest(
            units=units, interval_seconds=interval))

    @staticmethod
    def _check(result: pb.OpResult, op: str) -> None:
        if not result.ok:
            raise AgentError(op, result.message)
