// Four-step wizard mirroring the backend contract: POST /api/projects with an
// explicit stack + start_command (server-side auto-detect runs during the
// pipeline for redeploys; pre-clone detection is a future backend endpoint).
import { useReducer } from "react";
import { useNavigate } from "react-router-dom";
import { useMutation } from "@tanstack/react-query";
import { createProject } from "../api";
import { useI18n, type MsgKey } from "../i18n";
import type { NewProjectPayload } from "../types";

const ALIAS_RX = /^[a-z0-9][a-z0-9-]{1,39}$/;
const DOMAIN_RX = /^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$/;
const GIT_RX = /^(https:\/\/|[\w.-]+@[\w.-]+:)/;

type Stack = NewProjectPayload["stack"];

const STACK_DEFAULTS: Record<Stack, { build: string; start: string; hintKey: MsgKey }> = {
  node: { build: "npm ci\nnpm run build", start: "npm run start", hintKey: "hint.node" },
  python: {
    build: "python3 -m venv .venv\n.venv/bin/pip install -r requirements.txt",
    start: ".venv/bin/uvicorn main:app --host 127.0.0.1 --port {port}",
    hintKey: "hint.python",
  },
  go: { build: "go build -o app .", start: "./app", hintKey: "hint.go" },
  static: { build: "", start: "", hintKey: "hint.static" },
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

// Technical inputs (aliases, URLs, commands) are LTR content regardless of UI language.
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
  const { t } = useI18n();
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

  const aliasErr = s.alias && !ALIAS_RX.test(s.alias) ? t("wizard.aliasErr") : null;
  const gitErr = s.git_url && !GIT_RX.test(s.git_url) ? t("wizard.gitErr") : null;
  const domainErr = s.domain && !DOMAIN_RX.test(s.domain) ? t("wizard.domainErr") : null;

  const stepValid = [
    Boolean(s.alias && s.git_url && !aliasErr && !gitErr),
    Boolean(s.stack === "static" || s.start),
    Boolean(s.domain && !domainErr),
    true,
  ][s.step];

  const stepKeys: MsgKey[] = ["wizard.step.source", "wizard.step.stack", "wizard.step.domain", "wizard.step.review"];

  return (
    <div className="mx-auto max-w-2xl space-y-6">
      <h1 className="text-xl font-semibold text-zinc-100">{t("wizard.title")}</h1>

      <ol className="flex gap-2 text-xs">
        {stepKeys.map((key, i) => (
          <li
            key={key}
            className={`flex items-center gap-1.5 rounded-full px-3 py-1 ${
              i === s.step ? "bg-emerald-900/60 text-emerald-300"
                : i < s.step ? "bg-zinc-800 text-zinc-300" : "bg-zinc-900 text-zinc-600"
            }`}
          >
            <span className="tabular-nums">{i + 1}</span> {t(key)}
          </li>
        ))}
      </ol>

      <div className="space-y-4 rounded-lg border border-zinc-800 bg-zinc-900/60 p-5">
        {s.step === 0 && (
          <>
            <Label text={t("wizard.alias")} error={aliasErr}>
              <input dir="ltr" className={input} value={s.alias} onChange={set("alias")} placeholder="api-server" />
            </Label>
            <Label text={t("wizard.repo")} error={gitErr}>
              <input dir="ltr" className={input} value={s.git_url} onChange={set("git_url")}
                     placeholder="https://github.com/org/repo.git" />
            </Label>
            <Label text={t("wizard.branch")}>
              <input dir="ltr" className={input} value={s.branch} onChange={set("branch")} />
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
            <p className="text-xs text-zinc-500">{t(STACK_DEFAULTS[s.stack].hintKey)}</p>
            {s.stack !== "static" && (
              <>
                <Label text={t("wizard.buildCommands")}>
                  <textarea dir="ltr" className={`${input} h-24 font-mono text-xs`} value={s.build} onChange={set("build")} />
                </Label>
                <Label text={t("wizard.startCommand")}>
                  <input dir="ltr" className={`${input} font-mono text-xs`} value={s.start} onChange={set("start")} />
                </Label>
              </>
            )}
          </>
        )}

        {s.step === 2 && (
          <>
            <Label text={t("wizard.domainLabel")} error={domainErr}>
              <input dir="ltr" className={input} value={s.domain} onChange={set("domain")} placeholder="api.example.com" />
            </Label>
            <p className="text-xs text-zinc-500">{t("wizard.domainHint")}</p>
          </>
        )}

        {s.step === 3 && (
          <dl className="grid grid-cols-[8rem_1fr] gap-y-2 text-sm">
            {([
              ["rv.alias", s.alias], ["rv.repo", `${s.git_url} @ ${s.branch}`],
              ["rv.stack", s.stack], ["rv.domain", s.domain],
              ["rv.build", s.build || t("wizard.buildNone")],
              ["rv.start", s.stack === "static" ? t("wizard.staticStart") : s.start],
              ["rv.port", t("wizard.portAuto")], ["rv.tls", t("wizard.tlsValue")],
            ] as [MsgKey, string][]).map(([key, value]) => (
              <div key={key} className="contents">
                <dt className="text-zinc-500">{t(key)}</dt>
                <dd dir="ltr" className="whitespace-pre-wrap text-start font-mono text-xs text-zinc-200">{value}</dd>
              </div>
            ))}
          </dl>
        )}

        {submit.isError && (
          <p dir="ltr" className="rounded border border-red-900 bg-red-950/50 px-3 py-2 text-start text-sm text-red-400">
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
          {t("wizard.back")}
        </button>
        {s.step < 3 ? (
          <button
            onClick={() => dispatch({ type: "nav", to: s.step + 1 })}
            disabled={!stepValid}
            className="rounded-md bg-emerald-700 px-4 py-1.5 text-sm text-white hover:bg-emerald-600 disabled:opacity-40"
          >
            {t("wizard.next")}
          </button>
        ) : (
          <button
            onClick={() => submit.mutate()}
            disabled={submit.isPending}
            className="rounded-md bg-emerald-700 px-4 py-1.5 text-sm text-white hover:bg-emerald-600 disabled:opacity-50"
          >
            {submit.isPending ? t("wizard.deploying") : t("wizard.deploy")}
          </button>
        )}
      </div>
    </div>
  );
}
