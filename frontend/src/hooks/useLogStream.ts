// WebSocket log consumer matching the orchestrator's frame/repeat protocol.
// - "frame"  → append a new line (bounded ring buffer)
// - "repeat" → bump the repeat counter on an existing line (collapsed floods)
// Reconnects resume losslessly from the last journald cursor.
import { useEffect, useReducer, useRef } from "react";

export interface LogFrame {
  frameId: number;
  ts: number;              // microseconds since epoch
  level: "error" | "warn" | "info" | "debug";
  msg: string;
  repeat: number;
}

const MAX_LINES = 5000;

type Ev =
  | { type: "frame"; frame: LogFrame }
  | { type: "repeat"; frameId: number; repeat: number }
  | { type: "status"; status: State["status"] }
  | { type: "clear" };

interface State {
  lines: LogFrame[];
  status: "connecting" | "open" | "reconnecting" | "closed";
}

function reducer(state: State, ev: Ev): State {
  switch (ev.type) {
    case "frame": {
      const lines = [...state.lines, ev.frame];
      return { ...state, lines: lines.length > MAX_LINES ? lines.slice(-MAX_LINES) : lines };
    }
    case "repeat": {
      // Repeats almost always target a recent line — search from the tail.
      const lines = [...state.lines];
      for (let i = lines.length - 1; i >= Math.max(0, lines.length - 200); i--) {
        if (lines[i].frameId === ev.frameId) {
          lines[i] = { ...lines[i], repeat: ev.repeat };
          break;
        }
      }
      return { ...state, lines };
    }
    case "status":
      return { ...state, status: ev.status };
    case "clear":
      return { ...state, lines: [] };
  }
}

export function useLogStream(projectId: number, tail = 200) {
  const [state, dispatch] = useReducer(reducer, { lines: [], status: "connecting" });
  const cursorRef = useRef("");
  const retryRef = useRef(0);

  useEffect(() => {
    let ws: WebSocket | null = null;
    let closedByUs = false;
    let retryTimer: number | undefined;

    const connect = () => {
      const proto = location.protocol === "https:" ? "wss" : "ws";
      const cursor = encodeURIComponent(cursorRef.current);
      ws = new WebSocket(
        `${proto}://${location.host}/api/projects/${projectId}/logs?tail=${tail}&cursor=${cursor}`,
      );
      ws.onopen = () => {
        retryRef.current = 0;
        dispatch({ type: "status", status: "open" });
      };
      ws.onmessage = (e) => {
        const m = JSON.parse(e.data);
        if (m.cursor) cursorRef.current = m.cursor;
        if (m.type === "frame") {
          dispatch({
            type: "frame",
            frame: { frameId: m.frame_id, ts: m.ts, level: m.level, msg: m.msg, repeat: m.repeat },
          });
        } else if (m.type === "repeat") {
          dispatch({ type: "repeat", frameId: m.frame_id, repeat: m.repeat });
        }
      };
      ws.onclose = () => {
        if (closedByUs) return;
        dispatch({ type: "status", status: "reconnecting" });
        const backoff = Math.min(1000 * 2 ** retryRef.current++, 15000);
        retryTimer = window.setTimeout(connect, backoff);
      };
    };

    connect();
    return () => {
      closedByUs = true;
      window.clearTimeout(retryTimer);
      ws?.close();
      dispatch({ type: "status", status: "closed" });
    };
  }, [projectId, tail]);

  return { ...state, clear: () => dispatch({ type: "clear" }) };
}
