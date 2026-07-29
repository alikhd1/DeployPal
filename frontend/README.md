# DeployPal Frontend — React dashboard

Stack: **React 18 + TypeScript + Vite**, TanStack Query (server state),
TanStack Virtual (log list), React Router, Tailwind v4. The topology graph and
sparklines are hand-rolled SVG components (`TopologyGraph`, `Sparkline`) — the
layout is inherently columnar and the charts are single-series, so graph/chart
libraries would cost more bundle than they'd earn. Total: ~83 KB gzipped.

Build with `npm run build` (type-checks, then emits `dist/`); the orchestrator
serves `dist/` with an SPA fallback so deep links survive refresh. `npm run dev`
proxies `/api` (incl. WebSockets) to an orchestrator on `127.0.0.1:8443`.

## Route & component tree

```
<App>                                  React Router + QueryClientProvider
├── <Shell>                            sidebar nav, host health strip (CPU/RAM/disk
│                                      from /api/system, live via WS), activity feed
│
├── /                 <DashboardPage>
│     ├── <StatCards>                  running / failed / total apps, cert expiries
│     ├── <TopologyGraph>              React Flow: domains → nginx → apps → deps;
│     │                                node color = status, click → project page
│     └── <ActivityFeed>               tail of /api/events
│
├── /projects         <RegistryPage>
│     └── <ProjectTable>               alias, domain, stack badge, port, status,
│           │                          origin chip ("discovered" → Adopt button)
│           └── <RowActions>           start/stop/restart (optimistic), deploy, logs
│
├── /projects/:id     <ProjectPage>    tabs:
│     ├── <OverviewTab>                domain, port, unit, git, cert expiry,
│     │     └── <ResourceCharts>       CPU/RAM sparklines (WS resource stream)
│     ├── <LogsTab>                    <LogViewer/> (below)
│     ├── <DeploymentsTab>             deployment_history list
│     │     └── <StepTimeline>         per-step status/duration; failed step's
│     │                                captured log opens in a drawer
│     └── <SettingsTab>                env editor, branch, danger zone
│
├── /deploy           <NewDeploymentWizard>     4 steps, state in a reducer:
│     ├── <StepSource>                alias, git URL, branch (validated live)
│     ├── <StepStack>                calls POST /api/projects/detect → shows
│     │                              detected stack + editable build/start cmds
│     ├── <StepDomain>               domain input, DNS A-record hint, TLS toggle
│     └── <StepReview>               summary incl. auto-allocated port → POST
│                                    /api/projects → jumps to <DeployProgress>
│           └── <DeployProgress>     live step checklist driven by WS
│                                    "deployment.step" events; failure shows the
│                                    step log inline with a Retry button
│
└── /dependencies     <DependencyPage>
      ├── <DependencyList>           each infra service: kind icon, version,
      │                              status, start/stop (confirm dialog lists
      │                              dependent projects first)
      └── <DependencyGraph>          global M-N graph from /api/topology/graph
```

## Data layer conventions

* REST via TanStack Query; every mutation invalidates `["projects"]`.
* One shared WebSocket (`/api/events`) feeds a tiny event-bus context; queries
  subscribe to topics (`topology.updated` → invalidate) instead of polling.
* Log streaming uses a dedicated WS per open LogViewer (see `useLogStream`).

## i18n & RTL

Two locales — English and Persian (فارسی) — via a dependency-free context in
`src/i18n/` (~60 lines + two flat dictionaries; the `fa` dict is typed against
`en`'s keys, so a missing translation is a compile error). The switcher in the
sidebar persists to localStorage and sets `<html lang dir>`; layout mirroring
is done with Tailwind logical utilities (`ms-*`, `border-e`, `text-start`),
so RTL needs no separate stylesheet. Technical content — logs, commands,
domains, unit names, the topology graph — is pinned `dir="ltr"` inside the
RTL page, and timestamps format through `fa-IR` (Persian digits) when active.

## Key implementation files

* `src/hooks/useEvents.tsx` — the shared `/api/events` WebSocket: one
  connection app-wide; incoming events invalidate the matching TanStack
  queries (push-driven refresh, no polling) and fan out to subscribers.
* `src/hooks/useLogStream.ts` — WS consumer with cursor-based reconnect and
  repeat-frame merging (matches the orchestrator's frame/repeat protocol).
* `src/components/LogViewer.tsx` — virtualized list, level filter chips,
  repeat badges (×N), follow-tail behavior.
* `src/components/TopologyGraph.tsx` — columnar SVG topology with bezier
  edges; project nodes navigate to their detail page.
* `src/pages/DeployWizard.tsx` — 4-step reducer-driven wizard mirroring the
  backend's validation rules; per-stack build/start defaults.
