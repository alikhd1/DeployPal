// Vertical pipeline timeline for one deployment's step machine.
import type { DeploymentStep } from "../types";

function duration(step: DeploymentStep): string {
  if (!step.finished_at) return "…";
  const ms = Date.parse(step.finished_at) - Date.parse(step.started_at);
  return ms >= 1000 ? `${(ms / 1000).toFixed(1)}s` : `${ms}ms`;
}

const ICON: Record<DeploymentStep["status"], { glyph: string; cls: string }> = {
  ok: { glyph: "✓", cls: "border-emerald-700 text-emerald-400" },
  failed: { glyph: "✕", cls: "border-red-700 text-red-400" },
  running: { glyph: "●", cls: "border-sky-700 text-sky-400 animate-pulse" },
};

export function StepTimeline({ steps }: { steps: DeploymentStep[] }) {
  if (steps.length === 0) {
    return <p className="text-sm text-zinc-500">queued — no steps recorded yet</p>;
  }
  return (
    <ol className="space-y-1">
      {steps.map((step) => {
        const icon = ICON[step.status];
        return (
          <li key={step.name}>
            <details className="group">
              <summary className="flex cursor-pointer list-none items-center gap-3 rounded px-2 py-1.5 hover:bg-zinc-800/50">
                <span className={`flex h-5 w-5 shrink-0 items-center justify-center rounded-full border text-[10px] ${icon.cls}`}>
                  {icon.glyph}
                </span>
                <span className="text-sm text-zinc-200">{step.name}</span>
                <span className="ml-auto text-xs tabular-nums text-zinc-500">{duration(step)}</span>
              </summary>
              {step.log && (
                <pre className="ml-8 mt-1 max-h-64 overflow-auto rounded bg-zinc-950 p-3 text-[11px] leading-relaxed text-zinc-400">
                  {step.log}
                </pre>
              )}
            </details>
          </li>
        );
      })}
    </ol>
  );
}
