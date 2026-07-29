// The shared /api/events WebSocket: one connection for the whole app.
// Incoming events invalidate the relevant queries (push-driven refresh — no
// polling) and fan out to any component-level subscribers.
import {
  createContext, useContext, useEffect, useRef, useState,
  type ReactNode,
} from "react";
import { useQueryClient } from "@tanstack/react-query";

export interface BusEvent {
  topic: string;
  project_id: number | null;
  payload: Record<string, unknown>;
  ts: number;
}

type Listener = (event: BusEvent) => void;

interface EventBusValue {
  status: "connecting" | "live" | "offline";
  subscribe: (fn: Listener) => () => void;
}

const EventsContext = createContext<EventBusValue>({
  status: "connecting",
  subscribe: () => () => {},
});

export function EventsProvider({ children }: { children: ReactNode }) {
  const [status, setStatus] = useState<EventBusValue["status"]>("connecting");
  const listeners = useRef<Set<Listener>>(new Set());
  const queryClient = useQueryClient();

  useEffect(() => {
    let ws: WebSocket | null = null;
    let closed = false;
    let retry = 0;
    let timer: number | undefined;

    const connect = () => {
      const proto = location.protocol === "https:" ? "wss" : "ws";
      ws = new WebSocket(`${proto}://${location.host}/api/events`);
      ws.onopen = () => {
        retry = 0;
        setStatus("live");
      };
      ws.onmessage = (e) => {
        const event = JSON.parse(e.data) as BusEvent;
        if (event.topic === "topology.updated") {
          queryClient.invalidateQueries({ queryKey: ["topology"] });
          queryClient.invalidateQueries({ queryKey: ["projects"] });
          queryClient.invalidateQueries({ queryKey: ["dependencies"] });
        } else if (event.topic.startsWith("deployment.")) {
          queryClient.invalidateQueries({ queryKey: ["deployments"] });
          queryClient.invalidateQueries({ queryKey: ["projects"] });
        }
        listeners.current.forEach((fn) => fn(event));
      };
      ws.onclose = () => {
        if (closed) return;
        setStatus("offline");
        timer = window.setTimeout(connect, Math.min(1000 * 2 ** retry++, 15000));
      };
    };

    connect();
    return () => {
      closed = true;
      window.clearTimeout(timer);
      ws?.close();
    };
  }, [queryClient]);

  const value: EventBusValue = {
    status,
    subscribe: (fn) => {
      listeners.current.add(fn);
      return () => listeners.current.delete(fn);
    },
  };
  return <EventsContext.Provider value={value}>{children}</EventsContext.Provider>;
}

export const useEventBus = () => useContext(EventsContext);

/** Subscribe to bus events for the lifetime of the component. */
export function useEventSubscription(fn: Listener) {
  const { subscribe } = useEventBus();
  const fnRef = useRef(fn);
  fnRef.current = fn;
  useEffect(() => subscribe((e) => fnRef.current(e)), [subscribe]);
}
