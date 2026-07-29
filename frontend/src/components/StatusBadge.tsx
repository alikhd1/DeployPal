import { useI18n } from "../i18n";

const STYLES: Record<string, string> = {
  running: "bg-emerald-950 text-emerald-400",
  succeeded: "bg-emerald-950 text-emerald-400",
  active: "bg-emerald-950 text-emerald-400",
  provisioning: "bg-sky-950 text-sky-400 animate-pulse",
  queued: "bg-sky-950 text-sky-400",
  stopped: "bg-zinc-800 text-zinc-400",
  inactive: "bg-zinc-800 text-zinc-400",
  new: "bg-zinc-800 text-zinc-400",
  failed: "bg-red-950 text-red-400",
  degraded: "bg-amber-950 text-amber-400",
  unknown: "bg-zinc-800 text-zinc-500",
};

export function StatusBadge({ status }: { status: string | null }) {
  const { t } = useI18n();
  const s = status ?? "unknown";
  return (
    <span
      className={`inline-block rounded px-2 py-0.5 text-[11px] font-medium ${
        STYLES[s] ?? STYLES.unknown
      }`}
    >
      {t(`status.${s}`)}
    </span>
  );
}

export function OriginChip({ origin }: { origin: string }) {
  const { t } = useI18n();
  if (origin === "provisioned") return null;
  return (
    <span className="inline-block rounded border border-violet-800 px-1.5 py-0.5 text-[10px] text-violet-400">
      {t(`origin.${origin}`)}
    </span>
  );
}
