import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { getProjects, getRecentEvents, getTopology, sweepNow } from "../api";
import { TopologyGraph } from "../components/TopologyGraph";
import { useEventSubscription, type BusEvent } from "../hooks/useEvents";
import { useI18n, type TFunc } from "../i18n";
import type { ActivityEvent } from "../types";

function StatCard({ label, value, tone }: { label: string; value: number; tone?: string }) {
  return (
    <div className="rounded-lg border border-zinc-800 bg-zinc-900/60 px-4 py-3">
      <div className={`text-2xl font-semibold tabular-nums ${tone ?? "text-zinc-100"}`}>{value}</div>
      <div className="text-xs text-zinc-500">{label}</div>
    </div>
  );
}

function describe(t: TFunc, topic: string, payload: Record<string, unknown>): string {
  switch (topic) {
    case "deployment.step":
      return t("event.step", { step: String(payload.step), status: String(payload.status) });
    case "deployment.succeeded":
      return t("event.succeeded");
    case "deployment.failed":
      return t("event.failed", { step: String(payload.step), error: String(payload.error) });
    case "topology.updated":
      return t("event.topology");
    case "discovery.error":
      return t("event.discoveryError", { error: String(payload.error) });
    case "service.install.step":
      return t("event.svcStep", {
        recipe: String(payload.recipe_id), step: String(payload.step),
        status: String(payload.status),
      });
    case "service.install.finished":
      return t(payload.ok ? "event.svcDone" : "event.svcFailed", {
        recipe: String(payload.recipe_id), action: String(payload.action),
      });
    default:
      return topic;
  }
}

function ActivityFeed() {
  const { t, intl } = useI18n();
  const history = useQuery({ queryKey: ["events"], queryFn: () => getRecentEvents(30) });
  const [live, setLive] = useState<BusEvent[]>([]);
  useEventSubscription((e) => setLive((prev) => [e, ...prev].slice(0, 30)));

  const rows: { key: string; topic: string; text: string; when: string }[] = [
    ...live.map((e, i) => ({
      key: `live-${i}`, topic: e.topic, text: describe(t, e.topic, e.payload),
      when: new Date(e.ts * 1000).toLocaleTimeString(intl),
    })),
    ...(history.data ?? []).map((e: ActivityEvent) => ({
      key: `db-${e.id}`, topic: e.topic, text: describe(t, e.topic, e.payload),
      when: new Date(e.created_at).toLocaleTimeString(intl),
    })),
  ].slice(0, 30);

  return (
    <div className="rounded-lg border border-zinc-800 bg-zinc-900/60">
      <h2 className="border-b border-zinc-800 px-4 py-2 text-sm font-medium text-zinc-300">
        {t("dashboard.activity")}
      </h2>
      <ul className="max-h-72 overflow-y-auto p-2 text-xs">
        {rows.length === 0 && <li className="px-2 py-1 text-zinc-600">{t("activity.none")}</li>}
        {rows.map((row) => (
          <li key={row.key} className="flex gap-2 rounded px-2 py-1 hover:bg-zinc-800/40">
            <span className="shrink-0 tabular-nums text-zinc-600">{row.when}</span>
            <span className={row.topic.includes("error") || row.topic.includes("failed")
              ? "text-red-400" : "text-zinc-300"}>
              {row.text}
            </span>
          </li>
        ))}
      </ul>
    </div>
  );
}

export function DashboardPage() {
  const { t } = useI18n();
  const projects = useQuery({ queryKey: ["projects"], queryFn: getProjects });
  const topology = useQuery({ queryKey: ["topology"], queryFn: getTopology });
  const queryClient = useQueryClient();
  const sweep = useMutation({
    mutationFn: sweepNow,
    onSettled: () => queryClient.invalidateQueries({ queryKey: ["topology"] }),
  });

  const all = projects.data ?? [];
  const running = all.filter((p) => p.status === "running").length;
  const failed = all.filter((p) => p.status === "failed").length;
  const deps = topology.data?.nodes.filter((n) => n.type === "dependency").length ?? 0;

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <h1 className="text-xl font-semibold text-zinc-100">{t("dashboard.title")}</h1>
        <button
          onClick={() => sweep.mutate()}
          disabled={sweep.isPending}
          className="rounded-md bg-zinc-800 px-3 py-1.5 text-sm text-zinc-200 hover:bg-zinc-700 disabled:opacity-50"
        >
          {sweep.isPending ? t("dashboard.sweeping") : t("dashboard.sweep")}
        </button>
      </div>
      {sweep.isError && (
        <p className="rounded border border-red-900 bg-red-950/50 px-3 py-2 text-sm text-red-400">
          {(sweep.error as Error).message}
        </p>
      )}

      <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
        <StatCard label={t("stat.running")} value={running} tone="text-emerald-400" />
        <StatCard label={t("stat.failed")} value={failed} tone={failed ? "text-red-400" : undefined} />
        <StatCard label={t("stat.totalApps")} value={all.length} />
        <StatCard label={t("stat.dependencies")} value={deps} />
      </div>

      <div className="rounded-lg border border-zinc-800 bg-zinc-900/60 p-4">
        <h2 className="mb-3 text-sm font-medium text-zinc-300">{t("dashboard.topology")}</h2>
        {topology.data && <TopologyGraph graph={topology.data} />}
      </div>

      <ActivityFeed />
    </div>
  );
}
