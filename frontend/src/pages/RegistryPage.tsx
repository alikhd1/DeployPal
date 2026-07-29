import { Link } from "react-router-dom";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { getProjects, projectAction, redeploy } from "../api";
import { OriginChip, StatusBadge } from "../components/StatusBadge";
import { useI18n } from "../i18n";
import type { Project } from "../types";

function RowActions({ project }: { project: Project }) {
  const { t } = useI18n();
  const queryClient = useQueryClient();
  const invalidate = () => queryClient.invalidateQueries({ queryKey: ["projects"] });
  const act = useMutation({
    mutationFn: (action: "start" | "stop" | "restart") => projectAction(project.id, action),
    onSettled: invalidate,
  });
  const deploy = useMutation({ mutationFn: () => redeploy(project.id), onSettled: invalidate });

  const btn = "rounded px-2 py-0.5 text-xs text-zinc-300 hover:bg-zinc-700 disabled:opacity-40";
  const busy = act.isPending || deploy.isPending;
  const controllable = project.systemd_unit !== null;

  return (
    <span className="flex gap-1">
      {project.status === "running" ? (
        <>
          <button className={btn} disabled={busy || !controllable} onClick={() => act.mutate("restart")}>
            {t("action.restart")}
          </button>
          <button className={btn} disabled={busy || !controllable} onClick={() => act.mutate("stop")}>
            {t("action.stop")}
          </button>
        </>
      ) : (
        <button className={btn} disabled={busy || !controllable} onClick={() => act.mutate("start")}>
          {t("action.start")}
        </button>
      )}
      {project.git_url && (
        <button className={btn} disabled={busy} onClick={() => deploy.mutate()}>
          {t("action.deploy")}
        </button>
      )}
      {(act.isError || deploy.isError) && (
        <span className="text-xs text-red-400" title={((act.error ?? deploy.error) as Error).message}>!</span>
      )}
    </span>
  );
}

export function RegistryPage() {
  const { t } = useI18n();
  const projects = useQuery({ queryKey: ["projects"], queryFn: getProjects });

  const headers = ["th.alias", "th.domain", "th.stack", "th.port", "th.status", "th.lastDeploy", "th.actions"] as const;

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <h1 className="text-xl font-semibold text-zinc-100">{t("registry.title")}</h1>
        <Link to="/deploy" className="rounded-md bg-emerald-700 px-3 py-1.5 text-sm text-white hover:bg-emerald-600">
          {t("registry.new")}
        </Link>
      </div>

      <div className="overflow-x-auto rounded-lg border border-zinc-800">
        <table className="w-full text-start text-sm">
          <thead className="bg-zinc-900 text-xs text-zinc-500">
            <tr>
              {headers.map((h) => (
                <th key={h} className="px-4 py-2 text-start font-medium">{t(h)}</th>
              ))}
            </tr>
          </thead>
          <tbody className="divide-y divide-zinc-800/70">
            {(projects.data ?? []).map((p) => (
              <tr key={p.id} className="hover:bg-zinc-900/50">
                <td className="px-4 py-2">
                  <Link to={`/projects/${p.id}`} className="font-medium text-zinc-100 hover:text-emerald-400" dir="ltr">
                    {p.alias}
                  </Link>{" "}
                  <OriginChip origin={p.origin} />
                </td>
                <td className="px-4 py-2 text-zinc-400" dir="ltr">
                  {p.domain ?? "—"}{p.tls_enabled ? <span className="ms-1 text-emerald-500" title="TLS">🔒</span> : null}
                </td>
                <td className="px-4 py-2 text-zinc-400" dir="ltr">{p.stack}</td>
                <td className="px-4 py-2 tabular-nums text-zinc-400" dir="ltr">{p.port ?? "—"}</td>
                <td className="px-4 py-2"><StatusBadge status={p.status} /></td>
                <td className="px-4 py-2"><StatusBadge status={p.last_deploy_status} /></td>
                <td className="px-4 py-2"><RowActions project={p} /></td>
              </tr>
            ))}
            {projects.data?.length === 0 && (
              <tr><td colSpan={7} className="px-4 py-8 text-center text-zinc-500">
                {t("registry.empty")}
              </td></tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}
