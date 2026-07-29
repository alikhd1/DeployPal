// Three-column SVG topology: domains → projects → dependencies.
// Lightweight on purpose (no graph library) — the layout is inherently
// columnar, so fixed columns + bezier edges read better than force layouts.
import { useNavigate } from "react-router-dom";
import { useI18n } from "../i18n";
import type { TopologyGraphData, TopologyNode } from "../types";

const COL_X: Record<TopologyNode["type"], number> = { domain: 20, project: 360, dependency: 700 };
const NODE_W = 200;
const NODE_H = 34;
const GAP = 14;

const FILL: Record<string, string> = {
  running: "fill-emerald-500", active: "fill-emerald-500",
  failed: "fill-red-500", stopped: "fill-zinc-500",
  provisioning: "fill-sky-500", degraded: "fill-amber-500",
};

export function TopologyGraph({ graph }: { graph: TopologyGraphData }) {
  const navigate = useNavigate();
  const { t } = useI18n();

  if (graph.nodes.length === 0) {
    return (
      <div className="flex h-40 items-center justify-center rounded-lg border border-dashed border-zinc-800 text-sm text-zinc-500">
        {t("topo.empty")}
      </div>
    );
  }

  // Column layout: y position = index within the node's own column.
  const pos = new Map<string, { x: number; y: number }>();
  const counts: Record<string, number> = {};
  for (const node of graph.nodes) {
    const row = counts[node.type] ?? 0;
    counts[node.type] = row + 1;
    pos.set(node.id, { x: COL_X[node.type], y: 20 + row * (NODE_H + GAP) });
  }
  const height = 40 + Math.max(...Object.values(counts), 0) * (NODE_H + GAP);

  return (
    // The graph reads left-to-right (edge → app → backing service) in both
    // locales; domain names and unit names are Latin-script anyway.
    <div dir="ltr">
    <svg viewBox={`0 0 920 ${height}`} className="w-full" style={{ maxHeight: 420 }}>
      {graph.edges.map((edge, i) => {
        const a = pos.get(edge.source);
        const b = pos.get(edge.target);
        if (!a || !b) return null;
        const x1 = a.x + NODE_W, y1 = a.y + NODE_H / 2;
        const x2 = b.x, y2 = b.y + NODE_H / 2;
        const mx = (x1 + x2) / 2;
        return (
          <g key={i}>
            <path
              d={`M${x1},${y1} C${mx},${y1} ${mx},${y2} ${x2},${y2}`}
              fill="none" strokeWidth="1.2" className="stroke-zinc-700"
            />
            {edge.label && (
              <text x={mx} y={(y1 + y2) / 2 - 4} textAnchor="middle"
                    className="fill-zinc-600 text-[9px]">{edge.label}</text>
            )}
          </g>
        );
      })}
      {graph.nodes.map((node) => {
        const p = pos.get(node.id)!;
        const clickable = node.type === "project";
        return (
          <g
            key={node.id}
            transform={`translate(${p.x},${p.y})`}
            className={clickable ? "cursor-pointer" : undefined}
            onClick={clickable ? () => navigate(`/projects/${node.id.split(":")[1]}`) : undefined}
          >
            <rect width={NODE_W} height={NODE_H} rx="6"
                  className={`stroke-zinc-700 ${clickable ? "fill-zinc-800 hover:fill-zinc-750" : "fill-zinc-900"}`} />
            <circle cx="14" cy={NODE_H / 2} r="4"
                    className={FILL[node.status ?? ""] ?? "fill-zinc-600"} />
            <text x="26" y={NODE_H / 2 + 4} className="fill-zinc-200 text-[12px]">
              {node.label.length > 22 ? node.label.slice(0, 21) + "…" : node.label}
            </text>
            {(node.stack || node.kind) && (
              <text x={NODE_W - 10} y={NODE_H / 2 + 4} textAnchor="end"
                    className="fill-zinc-500 text-[10px]">{node.stack ?? node.kind}</text>
            )}
          </g>
        );
      })}
    </svg>
    </div>
  );
}
