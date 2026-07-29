// Four-step wizard mirroring the backend contract: POST /api/projects with an
// explicit stack + start_command (server-side auto-detect runs during the
// pipeline for redeploys; pre-clone detection is a future backend endpoint).
import { useReducer } from "react";
import { useNavigate } from "react-router-dom";
import { useMutation } from "@tanstack/react-query";
import { createProject } from "../api";
import type { NewProjectPayload } from "../types";

const ALIAS_RX = /^[a-z0-9][a-z0-9-]{1,39}$/;
const DOMAIN_RX = /^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$/;
const GIT_RX = /^(https:\/\/|[\w.-]+@[\w.-]+:)/;

type Stack = NewProjectPayload["stack"];

const STACK_DEFAULTS: Record<Stack, { build: string; start: string; hint: string }> = {
  node: {
    build: "npm ci\nnpm run build",
    start: "npm run start",
    hint: "package.json project — PORT env var is injected by the systemd unit",
  },
  python: {
    build: "python3 -m venv .venv\n.venv/bin/pip install -r requirements.txt",
    start: ".venv/bin/uvicorn main:app --host 127.0.0.1 --port {port}",
    hint: "{port} is replaced with the auto-allocated port at deploy time",
  },
  go: { build: "go build -o app .", start: "./app", hint: "binary reads PORT from the environment" },
  static: { build: "", start: "", hint: "served directly by nginx — no process, no port" },
};

interface State {
  step: number;
  alias: string;
  git_url: string;
  branch: string;
  stack: Stack;
  build: string;
  start: string;
  domain: string;
  touchedCommands: boolean;
}

type Action =
  | { type: "set"; field: keyof State; value: string }
  | { type: "stack"; stack: Stack }
  | { type: "nav"; to: number };

const initial: State = {
  step: 0, alias: "", git_url: "", branch: "main",
  stack: "node", build: STACK_DEFAULTS.node.build, start: STACK_DEFAULTS.node.start,
  domain: "", touchedCommands: false,
};

function reducer(state: State, action: Action): State {
  switch (action.type) {
    case "set":
      return {
        ...state,
        [action.field]: action.value,
        touchedCommands: state.touchedCommands || action.field === "build" || action.field === "start",
      };
    case "stack":
      return {
        ...state,
        stack: action.stack,
        // don't clobber commands the user already edited
        build: state.touchedCommands ? state.build : STACK_DEFAULTS[action.stack].build,
        start: state.touchedCommands ? state.start : STACK_DEFAULTS[action.stack].start,
      };
    case "nav":
      return { ...state, step: action.to };
  }
}

const input =
  "w-full rounded-md border border-zinc-700 bg-zinc-900 px-3 py-1.5 text-sm text-zinc-100 " +
  "placeholder:text-zinc-600 focus:border-emerald-600 focus:outline-none";

function Label({ text, children, error }: { text: string; children: React.ReactNode; error?: string | null }) {
  return (
    <label className="block space-y-1">
      <span className="text-xs text-zinc-400">{text}</span>
      {children}
      {error && <span className="text-xs text-red-400">{error}</span>}
    </label>
  );
}

export function DeployWizard() {
  const [s, dispatch] = useReducer(reducer, initial);
  const navigate = useNavigate();
  const set = (field: keyof State) => (e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>) =>
    dispatch({ type: "set", field, value: e.target.value });

  const submit = useMutation({
    mutationFn: () =>
      createProject({
        alias: s.alias, git_url: s.git_url, branch: s.branch, domain: s.domain,
        stack: s.stack,
        build_commands: s.build.split("\n").map((l) => l.trim()).filter(Boolean),
        start_command: s.stack === "static" ? null : s.start,
      }),
    onSuccess: (r) => navigate(`/projects/${r.project_id}?tab=deployments`),
  });

  const aliasErr = s.alias && !ALIAS_RX.test(s.alias) ? "lowercase letters, digits, dashes (2–40)" : null;
  const gitErr = s.git_url && !GIT_RX.test(s.git_url) ? "https:// or ssh (user@host:path)" : null;
  const domainErr = s.domain && !DOMAIN_RX.test(s.domain) ? "not a valid domain" : null;

  const stepValid = [
    Boolean(s.alias && s.git_url && !aliasErr && !gitErr),
    Boolean(s.stack === "static" || s.start),
    Boolean(s.domain && !domainErr),
    true,
  ][s.step];

  const STEPS = ["Source", "Stack & build", "Domain", "Review"];

  return (
    <div className="mx-auto max-w-2xl space-y-6">
      <h1 className="text-xl font-semibold text-zinc-100">New deployment</h1>

      <ol className="flex gap-2 text-xs">
        {STEPS.map((label, i) => (
          <li
            key={label}
            className={`flex items-center gap-1.5 rounded-full px-3 py-1 ${
              i === s.step ? "bg-emerald-900/60 text-emerald-300"
                : i < s.step ? "bg-zinc-800 text-zinc-300" : "bg-zinc-900 text-zinc-600"
            }`}
          >
            <span className="tabular-nums">{i + 1}</span> {label}
          </li>
        ))}
      </ol>

      <div className="space-y-4 rounded-lg border border-zinc-800 bg-zinc-900/60 p-5">
        {s.step === 0 && (
          <>
            <Label text="Project alias" error={aliasErr}>
              <input className={input} value={s.alias} onChange={set("alias")} placeholder="api-server" />
            </Label>
            <Label text="Git repository (HTTPS or SSH)" error={gitErr}>
              <input className={input} value={s.git_url} onChange={set("git_url")}
                     placeholder="https://github.com/org/repo.git" />
            </Label>
            <Label text="Branch">
              <input className={input} value={s.branch} onChange={set("branch")} />
            </Label>
          </>
        )}

        {s.step === 1 && (
          <>
            <div className="flex gap-2">
              {(Object.keys(STACK_DEFAULTS) as Stack[]).map((stack) => (
                <button
                  key={stack}
                  onClick={() => dispatch({ type: "stack", stack })}
                  className={`rounded-md px-3 py-1.5 text-sm ${
                    s.stack === stack ? "bg-emerald-700 text-white" : "bg-zinc-800 text-zinc-300 hover:bg-zinc-700"
                  }`}
                >
                  {stack}
                </button>
              ))}
            </div>
            <p className="text-xs text-zinc-500">{STACK_DEFAULTS[s.stack].hint}</p>
            {s.stack !== "static" && (
              <>
                <Label text="Build commands (one per line)">
                  <textarea className={`${input} h-24 font-mono text-xs`} value={s.build} onChange={set("build")} />
                </Label>
                <Label text="Start command">
                  <input className={`${input} font-mono text-xs`} value={s.start} onChange={set("start")} />
                </Label>
              </>
            )}
          </>
        )}

        {s.step === 2 && (
          <>
            <Label text="Domain / subdomain" error={domainErr}>
              <input className={input} value={s.domain} onChange={set("domain")} placeholder="api.example.com" />
            </Label>
            <p className="text-xs text-zinc-500">
              Point an A record at this server first. A local port is auto-allocated; nginx and a
              Let's Encrypt certificate are provisioned automatically.
            </p>
          </>
        )}

        {s.step === 3 && (
          <dl className="grid grid-cols-[8rem_1fr] gap-y-2 text-sm">
            {[
              ["alias", s.alias], ["repository", `${s.git_url} @ ${s.branch}`],
              ["stack", s.stack], ["domain", s.domain],
              ["build", s.build || "(none)"], ["start", s.stack === "static" ? "(nginx-served)" : s.start],
              ["port", "auto-allocated (3000–3999)"], ["TLS", "Let's Encrypt via certbot"],
            ].map(([k, v]) => (
              <div key={k} className="contents">
                <dt className="text-zinc-500">{k}</dt>
                <dd className="whitespace-pre-wrap font-mono text-xs text-zinc-200">{v}</dd>
              </div>
            ))}
          </dl>
        )}

        {submit.isError && (
          <p className="rounded border border-red-900 bg-red-950/50 px-3 py-2 text-sm text-red-400">
            {(submit.error as Error).message}
          </p>
        )}
      </div>

      <div className="flex justify-between">
        <button
          onClick={() => dispatch({ type: "nav", to: s.step - 1 })}
          disabled={s.step === 0}
          className="rounded-md bg-zinc-800 px-4 py-1.5 text-sm text-zinc-300 disabled:opacity-40"
        >
          Back
        </button>
        {s.step < 3 ? (
          <button
            onClick={() => dispatch({ type: "nav", to: s.step + 1 })}
            disabled={!stepValid}
            className="rounded-md bg-emerald-700 px-4 py-1.5 text-sm text-white hover:bg-emerald-600 disabled:opacity-40"
          >
            Next
          </button>
        ) : (
          <button
            onClick={() => submit.mutate()}
            disabled={submit.isPending}
            className="rounded-md bg-emerald-700 px-4 py-1.5 text-sm text-white hover:bg-emerald-600 disabled:opacity-50"
          >
            {submit.isPending ? "Deploying…" : "Deploy"}
          </button>
        )}
      </div>
    </div>
  );
}
