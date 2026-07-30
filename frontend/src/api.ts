// Typed fetch layer. All paths are relative — in dev Vite proxies /api to the
// orchestrator; in production the orchestrator serves both.
import type {
  ActivityEvent, Dependency, Deployment, NewProjectPayload, Project,
  ResourceSample, ServiceCatalog, ServiceInstall, SystemInfo, TopologyGraphData,
} from "./types";

export class ApiError extends Error {
  constructor(public status: number, detail: string) {
    super(detail);
  }
}

async function api<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(`/api${path}`, {
    headers: { "Content-Type": "application/json" },
    ...init,
  });
  if (!res.ok) {
    let detail = `${res.status} ${res.statusText}`;
    try {
      const body = await res.json();
      if (typeof body.detail === "string") detail = body.detail;
      else if (body.detail) detail = JSON.stringify(body.detail);
    } catch {
      /* non-JSON error body */
    }
    throw new ApiError(res.status, detail);
  }
  return res.json() as Promise<T>;
}

export const getProjects = () => api<Project[]>("/projects");

export const createProject = (payload: NewProjectPayload) =>
  api<{ project_id: number; deployment_id: number; port: number }>("/projects", {
    method: "POST",
    body: JSON.stringify(payload),
  });

export const projectAction = (id: number, action: "start" | "stop" | "restart") =>
  api<{ status: string }>(`/projects/${id}/action`, {
    method: "POST",
    body: JSON.stringify({ action }),
  });

export const redeploy = (id: number) =>
  api<{ deployment_id: number }>(`/projects/${id}/deploy`, { method: "POST" });

export const getDeployments = async (id: number): Promise<Deployment[]> => {
  const rows = await api<(Omit<Deployment, "steps"> & { steps: string })[]>(
    `/projects/${id}/deployments`,
  );
  return rows.map((r) => ({ ...r, steps: JSON.parse(r.steps || "[]") }));
};

export const getResources = (id: number, minutes = 60) =>
  api<ResourceSample[]>(`/projects/${id}/resources?minutes=${minutes}`);

export const getTopology = () => api<TopologyGraphData>("/topology");
export const getDependencies = () => api<Dependency[]>("/topology/dependencies");
export const sweepNow = () => api<{ status: string }>("/topology/sweep", { method: "POST" });

// service catalog — always served live from the agent, never cached server-side
export const getServiceCatalog = () => api<ServiceCatalog>("/services");

export const installService = (recipeId: string, params: Record<string, string>) =>
  api<{ install_id: number }>(`/services/${recipeId}/install`, {
    method: "POST",
    body: JSON.stringify({ params }),
  });

export const removeService = (recipeId: string, purge: boolean, force = false) =>
  api<{ install_id: number }>(`/services/${recipeId}/remove`, {
    method: "POST",
    body: JSON.stringify({ purge, force }),
  });

export const getServiceInstall = async (id: number): Promise<ServiceInstall> => {
  const row = await api<Omit<ServiceInstall, "steps"> & { steps: string }>(
    `/services/installs/${id}`,
  );
  return { ...row, steps: JSON.parse(row.steps || "[]") };
};

/** One-time reveal; the orchestrator discards the secrets after this call. */
export const getInstallSecrets = (id: number) =>
  api<{ secrets: Record<string, string> }>(`/services/installs/${id}/secrets`);

export const getSystem = () => api<SystemInfo>("/system");
export const getRecentEvents = (limit = 30) =>
  api<ActivityEvent[]>(`/events/recent?limit=${limit}`);
