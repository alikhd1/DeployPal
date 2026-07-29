// Minimal SVG sparkline: single series, no axes, current value on the right.
interface Props {
  points: number[];
  format?: (v: number) => string;
  width?: number;
  height?: number;
  className?: string; // controls stroke color via text-*
}

export function Sparkline({ points, format, width = 160, height = 36, className = "text-emerald-400" }: Props) {
  if (points.length < 2) {
    return <span className="text-xs text-zinc-600">no samples</span>;
  }
  const min = Math.min(...points);
  const max = Math.max(...points);
  const span = max - min || 1;
  const step = width / (points.length - 1);
  const path = points
    .map((v, i) => `${i === 0 ? "M" : "L"}${(i * step).toFixed(1)},${(height - 4 - ((v - min) / span) * (height - 8)).toFixed(1)}`)
    .join(" ");
  const last = points[points.length - 1];

  return (
    <span className="inline-flex items-center gap-2">
      <svg width={width} height={height} className={className} aria-hidden>
        <path d={path} fill="none" stroke="currentColor" strokeWidth="1.5" />
      </svg>
      <span className="text-xs tabular-nums text-zinc-300">{format ? format(last) : last.toFixed(1)}</span>
    </span>
  );
}
