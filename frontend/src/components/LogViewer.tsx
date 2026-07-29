// Virtualized log viewer: level filter chips, repeat badges (×N), follow-tail
// that disengages when the user scrolls up and re-engages via the jump button.
import { useMemo, useRef, useState } from "react";
import { useVirtualizer } from "@tanstack/react-virtual";
import { useLogStream, LogFrame } from "../hooks/useLogStream";

const LEVEL_STYLE: Record<LogFrame["level"], string> = {
  error: "text-red-400",
  warn: "text-amber-400",
  info: "text-zinc-300",
  debug: "text-zinc-500",
};

export function LogViewer({ projectId }: { projectId: number }) {
  const { lines, status, clear } = useLogStream(projectId);
  const [levels, setLevels] = useState<Set<string>>(new Set(["error", "warn", "info", "debug"]));
  const [follow, setFollow] = useState(true);
  const scrollRef = useRef<HTMLDivElement>(null);

  const visible = useMemo(() => lines.filter((l) => levels.has(l.level)), [lines, levels]);

  const virtualizer = useVirtualizer({
    count: visible.length,
    getScrollElement: () => scrollRef.current,
    estimateSize: () => 22,
    overscan: 30,
  });

  // Follow tail: scroll to the last row whenever new content arrives.
  if (follow && visible.length > 0) {
    virtualizer.scrollToIndex(visible.length - 1, { align: "end" });
  }

  const onScroll = () => {
    const el = scrollRef.current;
    if (!el) return;
    const atBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 40;
    if (follow !== atBottom) setFollow(atBottom);
  };

  return (
    <div className="flex h-full flex-col rounded-lg border border-zinc-800 bg-zinc-950">
      <div className="flex items-center gap-2 border-b border-zinc-800 px-3 py-2">
        {(["error", "warn", "info", "debug"] as const).map((lvl) => (
          <button
            key={lvl}
            onClick={() =>
              setLevels((prev) => {
                const next = new Set(prev);
                next.has(lvl) ? next.delete(lvl) : next.add(lvl);
                return next;
              })
            }
            className={`rounded px-2 py-0.5 text-xs uppercase ${
              levels.has(lvl) ? "bg-zinc-700 " + LEVEL_STYLE[lvl] : "text-zinc-600"
            }`}
          >
            {lvl}
          </button>
        ))}
        <span className="ml-auto text-xs text-zinc-500">{status}</span>
        <button onClick={clear} className="text-xs text-zinc-500 hover:text-zinc-300">
          clear
        </button>
      </div>

      <div ref={scrollRef} onScroll={onScroll} className="flex-1 overflow-y-auto font-mono text-xs">
        <div style={{ height: virtualizer.getTotalSize(), position: "relative" }}>
          {virtualizer.getVirtualItems().map((row) => {
            const line = visible[row.index];
            return (
              <div
                key={line.frameId}
                className={`absolute left-0 flex w-full gap-2 whitespace-pre px-3 ${LEVEL_STYLE[line.level]}`}
                style={{ transform: `translateY(${row.start}px)` }}
              >
                <span className="shrink-0 text-zinc-600">
                  {new Date(line.ts / 1000).toLocaleTimeString()}
                </span>
                <span className="overflow-hidden text-ellipsis">{line.msg}</span>
                {line.repeat > 1 && (
                  <span className="shrink-0 rounded bg-zinc-800 px-1.5 text-zinc-400">
                    ×{line.repeat}
                  </span>
                )}
              </div>
            );
          })}
        </div>
      </div>

      {!follow && (
        <button
          onClick={() => setFollow(true)}
          className="absolute bottom-4 right-6 rounded-full bg-zinc-700 px-3 py-1 text-xs shadow"
        >
          ↓ following paused — jump to tail
        </button>
      )}
    </div>
  );
}
