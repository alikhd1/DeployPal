import { Link, useParams, useSearchParams } from "react-router-dom";
import { useQuery } from "@tanstack/react-query";
import { getDeployments, getProjects, getResources } from "../api";
import { LogViewer } from "../components/LogViewer";
import { Sparkline } from "../components/Sparkline";
import { StatusBadge } from "../components/StatusBadge";
import { StepTimeline } from "../components/StepTimeline";
import type { Project } from "../types";

const TABS = ["overview", "logs", "deployments"] as const;
type Tab = (typeof TABS)[number];

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div>
      <dt className="text-xs text-zinc-500">{label}</dt>
      <dd className="text-sm text-zinc-200">{children ?? "—"}</dd>
    </div>
  );
}

function OverviewTab({ project }: { project: Project }) {
  const resources = useQuery({
    queryKey: ["resources", project.id],
    queryFn: () => getResources(project.id, 60),
    refetchInterval: 15_000,
  });
  const samples = resources.data ?? [];

  return (
    <div className="space-y-6">
      <dl className="grid grid-cols-2 gap-4 rounded-lg border border-zinc-800 bg-zinc-900/60 p-4 md:grid-cols-3">
        <Field label="domain">{project.domain}</Field>
        <Field label="local port">{project.port}</Field>
        <Field label="stack">{project.stack}</Field>
        <Field label="systemd unit">{project.systemd_unit}</Field>
        <Field label="root">{project.root_dir}</Field>
        <Field label="git">
          {project.git_url ? `${project.git_url} @ ${project.git_branch}` : "—"}
        </Field>
        <Field label="TLS">{project.tls_enabled ? `enabled${project.cert_expires_at ? ` (expires ${project.cert_expires_at.slice(0, 10)})` : ""}` : "off"}</Field>
        <Field label="origin">{project.origin}</Field>
        <Field label="last seen">{project.last_seen_at?.replace("T", " ").slice(0, 19)}</Field>
      </dl>

      <div className="rounded-lg border border-zinc-800 bg-zinc-900/60 p-4">
        <h3 className="mb-3 text-sm font-medium text-zinc-300">Resources (last hour)</h3>
        <div className="flex flex-wrap gap-10">
          <div>
            <div className="mb-1 text-xs text-zinc-500">CPU</div>
            <Sparkline points={samples.map((s) => s.cpu_percent)} format={(v) => `${v.toFixed(1)}%`} />
          </div>
          <div>
            <div className="mb-1 text-xs text-zinc-500">Memory</div>
            <Sparkline
              points={samples.map((s) => s.mem_bytes / (1 << 20))}
              format={(v) => `${v.toFixed(0)} MiB`}
              className="text-sky-400"
            />
          </div>
        </div>
      </div>
    </div>
  );
}

function DeploymentsTab({ projectId }: { projectId: number }) {
  const deployments = useQuery({
    queryKey: ["deployments", projectId],
    queryFn: () => getDeployments(projectId),
  });

  return (
    <div className="space-y-3">
      {(deployments.data ?? []).map((d, i) => (
        <details key={d.id} open={i === 0} className="rounded-lg border border-zinc-800 bg-zinc-900/60">
          <summary className="flex cursor-pointer items-center gap-3 px-4 py-2.5">
            <StatusBadge status={d.status} />
            <span className="text-sm text-zinc-200">{d.kind}</span>
            <span className="text-xs text-zinc-500">
              {d.git_ref}{d.git_commit ? ` @ ${d.git_commit.slice(0, 8)}` : ""}
            </span>
            <span className="ml-auto text-xs tabular-nums text-zinc-500">
              {d.started_at.replace("T", " ").slice(0, 19)}
            </span>
          </summary>
          <div className="border-t border-zinc-800 p-4">
            {d.error && (
              <p className="mb-3 rounded border border-red-900 bg-red-950/50 px-3 py-2 text-xs text-red-400">{d.error}</p>
            )}
            <StepTimeline steps={d.steps} />
          </div>
        </details>
      ))}
      {deployments.data?.length === 0 && (
        <p className="text-sm text-zinc-500">No deployments recorded for this project.</p>
      )}
    </div>
  );
}

export function ProjectPage() {
  const { id } = useParams();
  const projectId = Number(id);
  const [params, setParams] = useSearchParams();
  const tab = (TABS.includes(params.get("tab") as Tab) ? params.get("tab") : "overview") as Tab;

  // Reuses the registry query; a dedicated GET /api/projects/{id} can come later.
  const projects = useQuery({ queryKey: ["projects"], queryFn: getProjects });
  const project = projects.data?.find((p) => p.id === projectId);

  if (projects.isLoading) return <p className="text-sm text-zinc-500">loading…</p>;
  if (!project) {
    return (
      <p className="text-sm text-zinc-500">
        Project not found. <Link className="text-emerald-400" to="/projects">Back to registry</Link>
      </p>
    );
  }

  return (
    <div className="flex h-full flex-col space-y-4">
      <div className="flex items-center gap-3">
        <h1 className="text-xl font-semibold text-zinc-100">{project.alias}</h1>
        <StatusBadge status={project.status} />
      </div>

      <nav className="flex gap-1 border-b border-zinc-800">
        {TABS.map((t) => (
          <button
            key={t}
            onClick={() => setParams({ tab: t })}
            className={`border-b-2 px-3 py-1.5 text-sm ${
              tab === t
                ? "border-emerald-500 text-zinc-100"
                : "border-transparent text-zinc-500 hover:text-zinc-300"
            }`}
          >
            {t}
          </button>
        ))}
      </nav>

      {tab === "overview" && <OverviewTab project={project} />}
      {tab === "logs" && (
        <div className="relative min-h-0 flex-1">
          <LogViewer projectId={project.id} />
        </div>
      )}
      {tab === "deployments" && <DeploymentsTab projectId={project.id} />}
    </div>
  );
}
