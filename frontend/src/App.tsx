import { NavLink, Route, Routes } from "react-router-dom";
import { useQuery } from "@tanstack/react-query";
import { getSystem } from "./api";
import { useEventBus } from "./hooks/useEvents";
import { DashboardPage } from "./pages/DashboardPage";
import { RegistryPage } from "./pages/RegistryPage";
import { ProjectPage } from "./pages/ProjectPage";
import { DeployWizard } from "./pages/DeployWizard";
import { DependencyPage } from "./pages/DependencyPage";

const NAV = [
  { to: "/", label: "Dashboard", exact: true },
  { to: "/projects", label: "Projects" },
  { to: "/deploy", label: "New deployment" },
  { to: "/dependencies", label: "Dependencies" },
];

function fmtBytes(n: number): string {
  if (n >= 1 << 30) return `${(n / (1 << 30)).toFixed(1)} GiB`;
  if (n >= 1 << 20) return `${(n / (1 << 20)).toFixed(0)} MiB`;
  return `${n} B`;
}

function HostStrip() {
  const { status } = useEventBus();
  const system = useQuery({ queryKey: ["system"], queryFn: getSystem, retry: false, refetchInterval: 30_000 });

  return (
    <div className="flex items-center gap-4 border-b border-zinc-800 bg-zinc-925 px-6 py-2 text-xs text-zinc-400">
      {system.data ? (
        <>
          <span className="font-medium text-zinc-200">{system.data.hostname}</span>
          <span>{system.data.distro}</span>
          <span>load {system.data.load1.toFixed(2)}</span>
          <span>{system.data.cpu_count} cpu</span>
          <span>{fmtBytes(system.data.mem_total)} ram</span>
          <span>{fmtBytes(system.data.disk_free)} free</span>
        </>
      ) : (
        <span className="rounded bg-amber-950 px-2 py-0.5 text-amber-400">
          agent offline — discovery and provisioning unavailable
        </span>
      )}
      <span className="ml-auto flex items-center gap-1.5">
        <span
          className={`h-2 w-2 rounded-full ${
            status === "live" ? "bg-emerald-500" : status === "offline" ? "bg-red-500" : "bg-zinc-600"
          }`}
        />
        events {status}
      </span>
    </div>
  );
}

export default function App() {
  return (
    <div className="flex h-screen">
      <aside className="flex w-52 shrink-0 flex-col border-r border-zinc-800 bg-zinc-900/50">
        <div className="px-5 py-4 text-lg font-semibold tracking-tight text-zinc-100">
          Deploy<span className="text-emerald-400">Pal</span>
        </div>
        <nav className="flex flex-col gap-1 px-3">
          {NAV.map((item) => (
            <NavLink
              key={item.to}
              to={item.to}
              end={item.exact}
              className={({ isActive }) =>
                `rounded-md px-3 py-1.5 text-sm ${
                  isActive
                    ? "bg-zinc-800 text-zinc-100"
                    : "text-zinc-400 hover:bg-zinc-800/50 hover:text-zinc-200"
                }`
              }
            >
              {item.label}
            </NavLink>
          ))}
        </nav>
        <div className="mt-auto px-5 py-3 text-[10px] text-zinc-600">
          smise-navi · self-hosted control plane
        </div>
      </aside>

      <div className="flex min-w-0 flex-1 flex-col">
        <HostStrip />
        <main className="min-h-0 flex-1 overflow-y-auto p-6">
          <Routes>
            <Route path="/" element={<DashboardPage />} />
            <Route path="/projects" element={<RegistryPage />} />
            <Route path="/projects/:id" element={<ProjectPage />} />
            <Route path="/deploy" element={<DeployWizard />} />
            <Route path="/dependencies" element={<DependencyPage />} />
          </Routes>
        </main>
      </div>
    </div>
  );
}
