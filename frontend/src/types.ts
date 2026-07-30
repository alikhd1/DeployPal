// API row shapes, mirroring the orchestrator's SQLite schema / endpoints.

export interface Project {
  id: number;
  alias: string;
  origin: "provisioned" | "discovered" | "adopted";
  git_url: string | null;
  git_branch: string | null;
  root_dir: string;
  stack: "node" | "python" | "go" | "static" | "docker" | "unknown";
  port: number | null;
  start_command: string | null;
  systemd_unit: string | null;
  domain: string | null;
  tls_enabled: 0 | 1;
  cert_expires_at: string | null;
  status: "new" | "provisioning" | "running" | "stopped" | "failed" | "degraded" | "archived";
  last_seen_at: string | null;
  created_at: string;
  updated_at: string;
  last_deploy_status: string | null;
}

export interface DependencyConsumer {
  id: number;
  alias: string;
  source: string;
  evidence: string | null;
  database_name: string | null;
}

export interface Dependency {
  id: number;
  kind: string;
  name: string;
  host: string;
  port: number;
  version: string | null;
  runtime: string;
  systemd_unit: string | null;
  status: "active" | "inactive" | "unknown";
  consumers: DependencyConsumer[];
}

export interface TopologyNode {
  id: string;
  type: "domain" | "project" | "dependency";
  label: string;
  status?: string;
  stack?: string;
  kind?: string;
  origin?: string;
  enabled?: boolean;
}

export interface TopologyEdge {
  source: string;
  target: string;
  label?: string | null;
}

export interface TopologyGraphData {
  nodes: TopologyNode[];
  edges: TopologyEdge[];
}

export interface DeploymentStep {
  name: string;
  status: "running" | "ok" | "failed";
  started_at: string;
  finished_at: string | null;
  log: string;
}

export interface Deployment {
  id: number;
  project_id: number;
  kind: string;
  git_ref: string | null;
  git_commit: string | null;
  status: "queued" | "running" | "succeeded" | "failed" | "rolled_back";
  current_step: string | null;
  steps: DeploymentStep[]; // parsed from the JSON column in api.ts
  error: string | null;
  started_at: string;
  finished_at: string | null;
}

export interface SystemInfo {
  hostname: string;
  kernel: string;
  distro: string;
  mem_total: number;
  cpu_count: number;
  load1: number;
  disk_total: number;
  disk_free: number;
  agent_version: string;
}

export interface ActivityEvent {
  id: number;
  topic: string;
  project_id: number | null;
  payload: Record<string, unknown>;
  created_at: string;
}

export interface ResourceSample {
  sampled_at: string;
  cpu_percent: number;
  mem_bytes: number;
  disk_bytes: number | null;
}

// ---- service catalog (agent-owned recipes) ----

export interface RecipeParam {
  name: string;
  type: "enum" | "int" | "port" | "string" | "secret";
  default: string;
  values: string[];
  min: number;
  max: number;
  required: boolean;
  advanced: boolean;
  derived_hint: string; // e.g. "25% of 15.6 GiB RAM" when computed from host facts
  unit_suffix: string;
}

export interface ServiceInstallSummary {
  id: number;
  action: "install" | "remove";
  status: "queued" | "running" | "succeeded" | "failed";
  error: string | null;
  started_at: string;
  finished_at: string | null;
}

export interface ServiceRecipe {
  id: string;
  kind: string; // dependencies.kind value, or "tool"
  name: string;
  description: string;
  unit: string;
  default_port: number;
  packages: string[];
  source: "builtin" | "overlay";
  installed: boolean;
  installed_version: string;
  config_path: string;
  params: RecipeParam[];
  last_install: ServiceInstallSummary | null;
  dependency: { id: number; recipe_id: string; port: number; status: string } | null;
}

export interface ServiceCatalog {
  catalog_version: string;
  recipes: ServiceRecipe[];
}

export interface ServiceInstall {
  id: number;
  recipe_id: string;
  action: "install" | "remove";
  dependency_id: number | null;
  params: string; // JSON
  catalog_version: string | null;
  status: "queued" | "running" | "succeeded" | "failed";
  current_step: string | null;
  steps: DeploymentStep[]; // parsed from the JSON column in api.ts
  error: string | null;
  started_at: string;
  finished_at: string | null;
}

export interface NewProjectPayload {
  alias: string;
  git_url: string;
  branch: string;
  domain: string;
  stack: "node" | "python" | "go" | "static";
  build_commands: string[];
  start_command: string | null;
}
