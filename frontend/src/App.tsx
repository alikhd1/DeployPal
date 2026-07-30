import { NavLink, Route, Routes } from "react-router-dom";
import { useQuery } from "@tanstack/react-query";
import { getSystem } from "./api";
import { useEventBus } from "./hooks/useEvents";
import { useI18n, type Locale, type MsgKey } from "./i18n";
import { DashboardPage } from "./pages/DashboardPage";
import { RegistryPage } from "./pages/RegistryPage";
import { ProjectPage } from "./pages/ProjectPage";
import { DeployWizard } from "./pages/DeployWizard";
import { DependencyPage } from "./pages/DependencyPage";
import { ServicesPage } from "./pages/ServicesPage";

const NAV: { to: string; key: MsgKey; exact?: boolean }[] = [
  { to: "/", key: "nav.dashboard", exact: true },
  { to: "/projects", key: "nav.projects" },
  { to: "/deploy", key: "nav.deploy" },
  { to: "/dependencies", key: "nav.dependencies" },
  { to: "/services", key: "nav.services" },
];

function fmtBytes(n: number): string {
  if (n >= 1 << 30) return `${(n / (1 << 30)).toFixed(1)} GiB`;
  if (n >= 1 << 20) return `${(n / (1 << 20)).toFixed(0)} MiB`;
  return `${n} B`;
}

function HostStrip() {
  const { status } = useEventBus();
  const { t } = useI18n();
  const system = useQuery({ queryKey: ["system"], queryFn: getSystem, retry: false, refetchInterval: 30_000 });

  return (
    <div className="flex items-center gap-4 border-b border-zinc-800 px-6 py-2 text-xs text-zinc-400">
      {system.data ? (
        <>
          <span className="font-medium text-zinc-200" dir="ltr">{system.data.hostname}</span>
          <span dir="ltr">{system.data.distro}</span>
          <span>{t("host.load", { v: system.data.load1.toFixed(2) })}</span>
          <span>{t("host.cpu", { n: system.data.cpu_count })}</span>
          <span>{t("host.ram", { v: fmtBytes(system.data.mem_total) })}</span>
          <span>{t("host.free", { v: fmtBytes(system.data.disk_free) })}</span>
        </>
      ) : (
        <span className="rounded bg-amber-950 px-2 py-0.5 text-amber-400">
          {t("shell.agentOffline")}
        </span>
      )}
      <span className="ms-auto flex items-center gap-1.5">
        <span
          className={`h-2 w-2 rounded-full ${
            status === "live" ? "bg-emerald-500" : status === "offline" ? "bg-red-500" : "bg-zinc-600"
          }`}
        />
        {t(status === "live" ? "events.live" : status === "offline" ? "events.offline" : "events.connecting")}
      </span>
    </div>
  );
}

function LanguageSwitch() {
  const { locale, setLocale } = useI18n();
  const opt = (value: Locale, label: string) => (
    <button
      onClick={() => setLocale(value)}
      className={`rounded px-2 py-0.5 ${
        locale === value ? "bg-zinc-700 text-zinc-100" : "text-zinc-500 hover:text-zinc-300"
      }`}
    >
      {label}
    </button>
  );
  return (
    <div className="flex gap-1 text-xs">
      {opt("en", "EN")}
      {opt("fa", "فارسی")}
    </div>
  );
}

export default function App() {
  const { t } = useI18n();
  return (
    <div className="flex h-screen">
      <aside className="flex w-52 shrink-0 flex-col border-e border-zinc-800 bg-zinc-900/50">
        <div className="px-5 py-4 text-lg font-semibold tracking-tight text-zinc-100" dir="ltr">
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
              {t(item.key)}
            </NavLink>
          ))}
        </nav>
        <div className="mt-auto space-y-2 px-5 py-3">
          <LanguageSwitch />
          <div className="text-[10px] text-zinc-600">{t("shell.tagline")}</div>
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
            <Route path="/services" element={<ServicesPage />} />
          </Routes>
        </main>
      </div>
    </div>
  );
}
