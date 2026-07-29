import { Link } from "react-router-dom";
import { useQuery } from "@tanstack/react-query";
import { getDependencies } from "../api";
import { StatusBadge } from "../components/StatusBadge";

const KIND_ICON: Record<string, string> = {
  postgresql: "🐘", mysql: "🐬", mariadb: "🐬", redis: "🔴", mongodb: "🍃",
  rabbitmq: "🐇", kafka: "🧵", elasticsearch: "🔎", memcached: "🧠", other: "📦",
};

export function DependencyPage() {
  const deps = useQuery({ queryKey: ["dependencies"], queryFn: getDependencies });

  return (
    <div className="space-y-4">
      <h1 className="text-xl font-semibold text-zinc-100">Dependencies</h1>
      <p className="text-sm text-zinc-500">
        Infrastructure services discovered on this host, and the applications connected to them.
      </p>

      <div className="grid gap-3 md:grid-cols-2">
        {(deps.data ?? []).map((dep) => (
          <div key={dep.id} className="rounded-lg border border-zinc-800 bg-zinc-900/60 p-4">
            <div className="flex items-center gap-3">
              <span className="text-xl">{KIND_ICON[dep.kind] ?? KIND_ICON.other}</span>
              <div>
                <div className="text-sm font-medium text-zinc-100">{dep.name}</div>
                <div className="text-xs text-zinc-500">
                  {dep.host}:{dep.port} · {dep.runtime}
                  {dep.systemd_unit ? ` · ${dep.systemd_unit}` : ""}
                </div>
              </div>
              <span className="ml-auto"><StatusBadge status={dep.status} /></span>
            </div>

            <div className="mt-3 border-t border-zinc-800 pt-3">
              <div className="mb-1.5 text-xs text-zinc-500">
                {dep.consumers.length
                  ? `${dep.consumers.length} connected application${dep.consumers.length > 1 ? "s" : ""}`
                  : "no known consumers"}
              </div>
              <div className="flex flex-wrap gap-1.5">
                {dep.consumers.map((c) => (
                  <Link
                    key={`${c.id}-${c.source}`}
                    to={`/projects/${c.id}`}
                    title={c.evidence ?? undefined}
                    className="rounded bg-zinc-800 px-2 py-0.5 text-xs text-zinc-300 hover:bg-zinc-700"
                  >
                    {c.alias}{c.database_name ? ` → ${c.database_name}` : ""}
                  </Link>
                ))}
              </div>
            </div>
          </div>
        ))}
        {deps.data?.length === 0 && (
          <p className="text-sm text-zinc-500">Nothing discovered yet.</p>
        )}
      </div>
    </div>
  );
}
