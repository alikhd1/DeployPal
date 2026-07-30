// Service catalog: install infrastructure services and admin tools from the
// agent-owned recipe catalog. The form is generated from each recipe's param
// schema (defaults resolved agent-side from host facts), and installs render
// the same live step timeline as deployments.
import { useMemo, useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import {
  ApiError, getInstallSecrets, getServiceCatalog, getServiceInstall,
  installService, removeService,
} from "../api";
import { StepTimeline } from "../components/StepTimeline";
import { useEventSubscription } from "../hooks/useEvents";
import { useI18n } from "../i18n";
import type { RecipeParam, ServiceRecipe } from "../types";

const KIND_ICON: Record<string, string> = {
  postgresql: "🐘", mysql: "🐬", mariadb: "🐬", redis: "🔴", mongodb: "🍃",
  rabbitmq: "🐇", kafka: "🧵", elasticsearch: "🔎", memcached: "🧠", tool: "🧰",
};

function ParamField({
  param, value, onChange,
}: {
  param: RecipeParam;
  value: string;
  onChange: (v: string) => void;
}) {
  const { t } = useI18n();
  const inputCls =
    "w-full rounded border border-zinc-700 bg-zinc-950 px-2 py-1.5 text-sm text-zinc-200 focus:border-emerald-600 focus:outline-none";
  return (
    <label className="block">
      <span className="mb-1 flex items-baseline gap-2 text-xs text-zinc-400">
        <span dir="ltr">{param.name}</span>
        {param.unit_suffix && <span dir="ltr" className="text-zinc-600">{param.unit_suffix}</span>}
        {param.derived_hint && (
          <span className="text-emerald-600" dir="ltr" title={t("svc.derivedTitle")}>
            ≈ {param.derived_hint}
          </span>
        )}
      </span>
      {param.type === "enum" ? (
        <select dir="ltr" className={inputCls} value={value} onChange={(e) => onChange(e.target.value)}>
          {param.values.map((v) => (
            <option key={v} value={v}>{v}</option>
          ))}
        </select>
      ) : (
        <input
          dir="ltr"
          className={inputCls}
          type={param.type === "int" || param.type === "port" ? "number" : "text"}
          min={param.min || undefined}
          max={param.max || undefined}
          value={value}
          placeholder={param.type === "secret" ? t("svc.secretPlaceholder") : undefined}
          onChange={(e) => onChange(e.target.value)}
        />
      )}
    </label>
  );
}

function InstallPanel({ recipe, onClose }: { recipe: ServiceRecipe; onClose: () => void }) {
  const { t } = useI18n();
  const queryClient = useQueryClient();
  const [values, setValues] = useState<Record<string, string>>(
    () => Object.fromEntries(recipe.params.map((p) => [p.name, p.default])),
  );
  const [installId, setInstallId] = useState<number | null>(null);
  const [secrets, setSecrets] = useState<Record<string, string> | null>(null);
  const [error, setError] = useState<string | null>(null);

  const basic = recipe.params.filter((p) => !p.advanced);
  const advanced = recipe.params.filter((p) => p.advanced);

  const install = useMutation({
    mutationFn: () => installService(recipe.id, values),
    onSuccess: (r) => setInstallId(r.install_id),
    onError: (e) => setError(e instanceof ApiError ? e.message : String(e)),
  });

  const progress = useQuery({
    queryKey: ["service-install", installId],
    queryFn: () => getServiceInstall(installId!),
    enabled: installId !== null,
    refetchInterval: (q) =>
      q.state.data && ["succeeded", "failed"].includes(q.state.data.status) ? false : 1500,
  });

  useEventSubscription((e) => {
    if (e.topic.startsWith("service.install.") && installId !== null) {
      queryClient.invalidateQueries({ queryKey: ["service-install", installId] });
      if (e.topic === "service.install.finished") {
        queryClient.invalidateQueries({ queryKey: ["services"] });
        queryClient.invalidateQueries({ queryKey: ["dependencies"] });
        if (e.payload.ok && e.payload.has_secrets && e.payload.install_id === installId) {
          getInstallSecrets(installId).then((r) => setSecrets(r.secrets)).catch(() => {});
        }
      }
    }
  });

  const done = progress.data && ["succeeded", "failed"].includes(progress.data.status);

  return (
    <div className="fixed inset-0 z-40 flex items-center justify-center bg-black/60 p-6" onClick={onClose}>
      <div
        className="max-h-[85vh] w-full max-w-lg overflow-y-auto rounded-lg border border-zinc-700 bg-zinc-900 p-5"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="mb-1 flex items-center gap-2">
          <span className="text-xl">{KIND_ICON[recipe.kind] ?? KIND_ICON.tool}</span>
          <h2 className="text-lg font-semibold text-zinc-100" dir="ltr">{recipe.name}</h2>
          <button onClick={onClose} className="ms-auto text-zinc-500 hover:text-zinc-300">✕</button>
        </div>
        <p className="mb-1 text-sm text-zinc-500">{recipe.description}</p>
        <p className="mb-4 text-xs text-zinc-600" dir="ltr">
          apt: {recipe.packages.join(", ")}
          {recipe.unit && ` · ${recipe.unit}`}
        </p>

        {installId === null ? (
          <>
            {recipe.params.length > 0 && (
              <div className="space-y-3">
                {basic.map((p) => (
                  <ParamField key={p.name} param={p} value={values[p.name] ?? ""}
                    onChange={(v) => setValues((prev) => ({ ...prev, [p.name]: v }))} />
                ))}
                {advanced.length > 0 && (
                  <details>
                    <summary className="cursor-pointer text-xs text-zinc-500 hover:text-zinc-300">
                      {t("svc.advanced")}
                    </summary>
                    <div className="mt-3 space-y-3">
                      {advanced.map((p) => (
                        <ParamField key={p.name} param={p} value={values[p.name] ?? ""}
                          onChange={(v) => setValues((prev) => ({ ...prev, [p.name]: v }))} />
                      ))}
                    </div>
                  </details>
                )}
              </div>
            )}
            {error && <p className="mt-3 text-sm text-red-400">{error}</p>}
            <button
              onClick={() => install.mutate()}
              disabled={install.isPending}
              className="mt-4 w-full rounded bg-emerald-700 py-2 text-sm font-medium text-white hover:bg-emerald-600 disabled:opacity-50"
            >
              {install.isPending
                ? t("svc.installing")
                : recipe.installed ? t("svc.reconfigure") : t("svc.install")}
            </button>
            <p className="mt-2 text-center text-[11px] text-zinc-600">{t("svc.installNote")}</p>
          </>
        ) : (
          <>
            <StepTimeline steps={progress.data?.steps ?? []} />
            {progress.data?.status === "failed" && (
              <p className="mt-3 rounded bg-red-950/60 p-2 text-sm text-red-400" dir="ltr">
                {progress.data.error}
              </p>
            )}
            {progress.data?.status === "succeeded" && (
              <p className="mt-3 text-sm text-emerald-400">
                {t(progress.data.action === "remove" ? "svc.removed" : "svc.succeeded")}
              </p>
            )}
            {secrets && (
              <div className="mt-3 rounded border border-amber-800 bg-amber-950/40 p-3">
                <p className="mb-2 text-xs font-medium text-amber-400">{t("svc.secretsOnce")}</p>
                {Object.entries(secrets).map(([k, v]) => (
                  <div key={k} className="font-mono text-xs text-amber-200" dir="ltr">
                    {k}={v}
                  </div>
                ))}
              </div>
            )}
            {done && (
              <button onClick={onClose}
                className="mt-4 w-full rounded bg-zinc-700 py-2 text-sm text-zinc-200 hover:bg-zinc-600">
                {t("svc.close")}
              </button>
            )}
          </>
        )}
      </div>
    </div>
  );
}

function ServiceCard({ recipe, onInstall, onRemove }: {
  recipe: ServiceRecipe;
  onInstall: () => void;
  onRemove: () => void;
}) {
  const { t } = useI18n();
  const busy = recipe.last_install?.status === "running";
  return (
    <div className="rounded-lg border border-zinc-800 bg-zinc-900/60 p-4">
      <div className="flex items-center gap-3">
        <span className="text-xl">{KIND_ICON[recipe.kind] ?? KIND_ICON.tool}</span>
        <div className="min-w-0">
          <div className="text-sm font-medium text-zinc-100" dir="ltr">
            {recipe.name}
            {recipe.installed && recipe.installed_version && (
              <span className="ms-2 text-xs text-zinc-500">{recipe.installed_version}</span>
            )}
          </div>
          <div className="truncate text-xs text-zinc-500">{recipe.description}</div>
        </div>
        <div className="ms-auto flex shrink-0 items-center gap-2">
          {recipe.installed ? (
            <>
              <span className="rounded bg-emerald-950 px-2 py-0.5 text-xs text-emerald-400">
                {t("svc.installed")}
              </span>
              {recipe.params.length > 0 && (
                <button onClick={onInstall} disabled={busy}
                  className="rounded bg-zinc-800 px-2 py-1 text-xs text-zinc-300 hover:bg-zinc-700 disabled:opacity-50">
                  {t("svc.configure")}
                </button>
              )}
              <button onClick={onRemove} disabled={busy}
                className="rounded bg-zinc-800 px-2 py-1 text-xs text-red-400 hover:bg-red-950 disabled:opacity-50">
                {t("svc.remove")}
              </button>
            </>
          ) : (
            <button onClick={onInstall} disabled={busy}
              className="rounded bg-emerald-800 px-3 py-1 text-xs font-medium text-white hover:bg-emerald-700 disabled:opacity-50">
              {busy ? t("svc.busy") : t("svc.install")}
            </button>
          )}
        </div>
      </div>
      {recipe.last_install?.status === "failed" && (
        <p className="mt-2 truncate text-xs text-red-500" dir="ltr" title={recipe.last_install.error ?? ""}>
          {t("svc.lastFailed")}: {recipe.last_install.error}
        </p>
      )}
    </div>
  );
}

export function ServicesPage() {
  const { t } = useI18n();
  const queryClient = useQueryClient();
  const catalog = useQuery({ queryKey: ["services"], queryFn: getServiceCatalog });
  const [installTarget, setInstallTarget] = useState<ServiceRecipe | null>(null);
  const [removeTarget, setRemoveTarget] = useState<ServiceRecipe | null>(null);
  const [removeError, setRemoveError] = useState<string | null>(null);

  useEventSubscription((e) => {
    if (e.topic === "service.install.finished") {
      queryClient.invalidateQueries({ queryKey: ["services"] });
    }
  });

  const remove = useMutation({
    mutationFn: ({ recipe, force }: { recipe: ServiceRecipe; force: boolean }) =>
      removeService(recipe.id, false, force),
    onSuccess: () => {
      setRemoveTarget(null);
      setRemoveError(null);
      queryClient.invalidateQueries({ queryKey: ["services"] });
    },
    onError: (e) => setRemoveError(e instanceof ApiError ? e.message : String(e)),
  });

  const [services, tools] = useMemo(() => {
    const all = catalog.data?.recipes ?? [];
    return [all.filter((r) => r.kind !== "tool"), all.filter((r) => r.kind === "tool")];
  }, [catalog.data]);

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-xl font-semibold text-zinc-100">{t("svc.title")}</h1>
        <p className="text-sm text-zinc-500">{t("svc.subtitle")}</p>
        {catalog.data && (
          <p className="mt-1 text-[11px] text-zinc-600" dir="ltr">
            catalog {catalog.data.catalog_version}
          </p>
        )}
      </div>

      {catalog.isError && <p className="text-sm text-red-400">{t("shell.agentOffline")}</p>}

      <section className="space-y-3">
        <h2 className="text-sm font-medium text-zinc-300">{t("svc.services")}</h2>
        <div className="grid gap-3 md:grid-cols-2">
          {services.map((r) => (
            <ServiceCard key={r.id} recipe={r}
              onInstall={() => setInstallTarget(r)}
              onRemove={() => { setRemoveError(null); setRemoveTarget(r); }} />
          ))}
        </div>
      </section>

      <section className="space-y-3">
        <h2 className="text-sm font-medium text-zinc-300">{t("svc.tools")}</h2>
        <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-3">
          {tools.map((r) => (
            <ServiceCard key={r.id} recipe={r}
              onInstall={() => setInstallTarget(r)}
              onRemove={() => { setRemoveError(null); setRemoveTarget(r); }} />
          ))}
        </div>
      </section>

      {installTarget && (
        <InstallPanel recipe={installTarget} onClose={() => setInstallTarget(null)} />
      )}

      {removeTarget && (
        <div className="fixed inset-0 z-40 flex items-center justify-center bg-black/60 p-6"
          onClick={() => setRemoveTarget(null)}>
          <div className="w-full max-w-md rounded-lg border border-zinc-700 bg-zinc-900 p-5"
            onClick={(e) => e.stopPropagation()}>
            <h2 className="mb-2 text-lg font-semibold text-zinc-100">
              {t("svc.removeTitle", { name: removeTarget.name })}
            </h2>
            <p className="mb-3 text-sm text-zinc-400">{t("svc.removeWarn")}</p>
            {removeError && (
              <p className="mb-3 rounded bg-red-950/60 p-2 text-sm text-red-400">{removeError}</p>
            )}
            <div className="flex gap-2">
              <button
                onClick={() => remove.mutate({ recipe: removeTarget, force: removeError !== null })}
                disabled={remove.isPending}
                className="rounded bg-red-800 px-3 py-1.5 text-sm text-white hover:bg-red-700 disabled:opacity-50"
              >
                {removeError ? t("svc.removeForce") : t("svc.remove")}
              </button>
              <button onClick={() => setRemoveTarget(null)}
                className="rounded bg-zinc-700 px-3 py-1.5 text-sm text-zinc-200 hover:bg-zinc-600">
                {t("svc.cancel")}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
