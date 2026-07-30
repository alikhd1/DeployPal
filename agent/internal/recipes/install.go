// install: the recipe execution engine — a small, fixed step machine
// (preflight → install → configure → restart → verify) mirroring the shape of
// the orchestrator's provisioning pipeline. All command argv is built here
// from recipe data; nothing caller-supplied ever reaches a shell.
//
// Sandbox note: the agent runs under ProtectSystem=strict, so its own mount
// namespace has a read-only /etc, /usr and /var. Every mutating operation
// (apt, config file writes, deletions) therefore executes in a transient
// systemd unit via `systemd-run --wait --pipe` — spawned by PID 1 outside the
// agent's sandbox, with argv still fully recipe-controlled. Reads, renders,
// and validation stay in-process.
package recipes

import (
	"bufio"
	"context"
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"text/template"
	"time"
)

const (
	managedHeader = "# managed-by: deploypal"
	secretsDir    = "/etc/deploypal/secrets"
	stagingDir    = "/run/deploypal/staging" // inside RuntimeDirectory → agent-writable
	minDiskFree   = 1 << 30                  // refuse to start an install with <1 GiB free on /
)

// dpkg/apt hold a single system-wide lock; serialize our own transactions and
// fail fast (clear message) instead of surfacing a cryptic dpkg lock error.
var aptMu sync.Mutex

// Emit streams one progress chunk to the client.
// status ∈ running|ok|failed; log may be a partial line batch.
type Emit func(step, status, log string)

// Result of a completed install, for the final stream message.
type Result struct {
	Facts   map[string]string
	Secrets map[string]string
}

// Install runs the full pipeline. Progress goes through emit; the returned
// error corresponds to the step that failed (already emitted as failed).
func Install(ctx context.Context, r *Recipe, userParams map[string]string, emit Emit) (*Result, error) {
	if !aptMu.TryLock() {
		return nil, fmt.Errorf("another package operation is already running")
	}
	defer aptMu.Unlock()

	params, generated, err := r.ValidateParams(userParams)
	if err != nil {
		emit("preflight", "failed", err.Error())
		return nil, err
	}

	// ---- preflight ----
	emit("preflight", "running", "")
	if err := preflight(r, params); err != nil {
		emit("preflight", "failed", err.Error())
		return nil, err
	}
	emit("preflight", "ok", "preflight checks passed")

	// ---- install ----
	emit("install", "running", "")
	if err := aptGet(ctx, emit, "install", append([]string{}, r.Packages...)); err != nil {
		emit("install", "failed", err.Error())
		return nil, err
	}
	emit("install", "ok", "")

	// ---- configure ----
	configPath := ""
	if r.Config != nil {
		emit("configure", "running", "")
		configPath, err = writeConfig(ctx, r, params)
		if err != nil {
			emit("configure", "failed", err.Error())
			return nil, err
		}
		if len(generated) > 0 {
			if err := writeSecretsFile(ctx, r.ID, generated); err != nil {
				emit("configure", "failed", err.Error())
				return nil, err
			}
		}
		emit("configure", "ok", "wrote "+configPath)
	}

	// ---- restart ----
	if r.Unit != "" {
		emit("restart", "running", "")
		if err := systemctl(ctx, "restart", r.Unit); err != nil {
			emit("restart", "failed", err.Error())
			return nil, err
		}
		if err := systemctl(ctx, "enable", r.Unit); err != nil {
			emit("restart", "failed", err.Error())
			return nil, err
		}
		emit("restart", "ok", "restarted "+r.Unit)
	}

	// ---- verify ----
	emit("verify", "running", "")
	version := InstalledVersion(r.Packages[0])
	if version == "" {
		err := fmt.Errorf("%s not registered in dpkg after install", r.Packages[0])
		emit("verify", "failed", err.Error())
		return nil, err
	}
	if r.VerifyPort {
		if err := dialWithRetry(effectivePort(r, params), 30*time.Second); err != nil {
			emit("verify", "failed", err.Error())
			return nil, err
		}
	}
	emit("verify", "ok", fmt.Sprintf("%s %s verified", r.Packages[0], version))

	facts := map[string]string{"version": version}
	if r.Unit != "" {
		facts["unit"] = r.Unit
	}
	if p := effectivePort(r, params); p != "" {
		facts["port"] = p
	}
	if configPath != "" {
		facts["config_path"] = configPath
	}
	return &Result{Facts: facts, Secrets: generated}, nil
}

// Remove stops the unit, removes the managed config, and apt-removes the
// packages. Deliberately a separate user-initiated action, never an
// automatic rollback: apt transactions aren't cleanly reversible.
func Remove(ctx context.Context, r *Recipe, purge bool, emit Emit) error {
	if !aptMu.TryLock() {
		return fmt.Errorf("another package operation is already running")
	}
	defer aptMu.Unlock()

	emit("remove", "running", "")
	if r.Unit != "" {
		if err := systemctl(ctx, "stop", r.Unit); err != nil {
			emit("remove", "running", "stop "+r.Unit+": "+err.Error()+" (continuing)")
		}
	}
	if r.Config != nil {
		if err := removeConfig(ctx, r); err != nil {
			emit("remove", "failed", err.Error())
			return err
		}
		emit("remove", "running", "removed managed config")
	}
	verb := "remove"
	if purge {
		verb = "purge"
	}
	if err := aptGet(ctx, emit, verb, append([]string{}, r.Packages...)); err != nil {
		emit("remove", "failed", err.Error())
		return err
	}
	_, _ = rootExec(ctx, "rm", "-f", filepath.Join(secretsDir, r.ID+".env"))
	emit("remove", "ok", "")
	return nil
}

// ---------------------------------------------------------------- steps

func preflight(r *Recipe, params map[string]string) error {
	if free := diskFreeBytes("/"); free > 0 && free < minDiskFree {
		return fmt.Errorf("only %d MiB free on / — need at least 1 GiB", free>>20)
	}
	if len(r.Conflicts) > 0 {
		cat, err := Load()
		if err != nil {
			return err
		}
		for _, conflictID := range r.Conflicts {
			if c := cat.Get(conflictID); c != nil && InstalledVersion(c.Packages[0]) != "" {
				return fmt.Errorf("conflicts with installed %s — remove it first", c.Name)
			}
		}
	}
	// Fresh install onto a port someone else holds → fail early with a clear
	// message. Re-configure of an already-installed service keeps its port.
	if port := effectivePort(r, params); port != "" && InstalledVersion(r.Packages[0]) == "" {
		if conn, err := net.DialTimeout("tcp", "127.0.0.1:"+port, 300*time.Millisecond); err == nil {
			conn.Close()
			return fmt.Errorf("port %s is already in use", port)
		}
	}
	return nil
}

func writeConfig(ctx context.Context, r *Recipe, params map[string]string) (string, error) {
	path, err := resolveConfigPath(r.Config.Path)
	if err != nil {
		return "", err
	}
	tpl, err := template.New(r.ID).Option("missingkey=error").Parse(r.Config.Template)
	if err != nil {
		return "", fmt.Errorf("config template: %w", err)
	}
	var buf strings.Builder
	buf.WriteString(managedHeader + "\n")
	buf.WriteString("# recipe: " + r.ID + " — do not edit; remove the service from DeployPal to restore defaults\n")
	if err := tpl.Execute(&buf, params); err != nil {
		return "", fmt.Errorf("config template: %w", err)
	}
	mode := "0644"
	if r.Config.Mode != "" {
		mode = r.Config.Mode
	}
	if err := installFile(ctx, []byte(buf.String()), path, mode, r.Config.Owner); err != nil {
		return "", err
	}
	if r.Config.IncludeInto != "" {
		if err := ensureIncludeLine(ctx, r.Config.IncludeInto, r.Config.IncludeLine); err != nil {
			return "", err
		}
	}
	return path, nil
}

func removeConfig(ctx context.Context, r *Recipe) error {
	if r.Config.IncludeInto != "" {
		if err := stripIncludeLine(ctx, r.Config.IncludeInto, r.Config.IncludeLine); err != nil && !os.IsNotExist(err) {
			return err
		}
	}
	path, err := resolveConfigPath(r.Config.Path)
	if err != nil {
		return nil // config dir already gone (e.g. purged) — nothing to remove
	}
	_, err = rootExec(ctx, "rm", "-f", path)
	return err
}

// resolveConfigPath expands a recipe glob like
// /etc/postgresql/*/main/conf.d/90-deploypal.conf against the real fs.
func resolveConfigPath(pattern string) (string, error) {
	if !strings.Contains(pattern, "*") {
		return pattern, nil
	}
	matches, err := filepath.Glob(pattern)
	if err != nil || len(matches) == 0 {
		return "", fmt.Errorf("config path %s matched nothing (package layout changed?)", pattern)
	}
	sort.Strings(matches)
	return matches[len(matches)-1], nil // newest version dir
}

// ensureIncludeLine appends the marker-guarded include to a distro config
// that has no conf.d mechanism (e.g. redis.conf). Idempotent: read in-process,
// rewrite through the sandbox escape preserving mode and owner.
func ensureIncludeLine(ctx context.Context, file, line string) error {
	raw, err := os.ReadFile(file)
	if err != nil {
		return err
	}
	if strings.Contains(string(raw), line) {
		return nil
	}
	next := strings.TrimRight(string(raw), "\n") + "\n\n" + managedHeader + "\n" + line + "\n"
	mode, owner, err := statModeOwner(file)
	if err != nil {
		return err
	}
	return installFile(ctx, []byte(next), file, mode, owner)
}

func stripIncludeLine(ctx context.Context, file, line string) error {
	raw, err := os.ReadFile(file)
	if err != nil {
		return err
	}
	var kept []string
	for _, l := range strings.Split(string(raw), "\n") {
		if strings.TrimSpace(l) == line || strings.TrimSpace(l) == managedHeader {
			continue
		}
		kept = append(kept, l)
	}
	mode, owner, err := statModeOwner(file)
	if err != nil {
		return err
	}
	return installFile(ctx, []byte(strings.Join(kept, "\n")), file, mode, owner)
}

func writeSecretsFile(ctx context.Context, recipeID string, secrets map[string]string) error {
	var buf strings.Builder
	buf.WriteString(managedHeader + "\n")
	names := make([]string, 0, len(secrets))
	for n := range secrets {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, n := range names {
		fmt.Fprintf(&buf, "%s=%s\n", strings.ToUpper(n), secrets[n])
	}
	if _, err := rootExec(ctx, "mkdir", "-p", "-m", "0700", secretsDir); err != nil {
		return err
	}
	return installFile(ctx, []byte(buf.String()),
		filepath.Join(secretsDir, recipeID+".env"), "0600", "")
}

// ---------------------------------------------------------------- helpers

// aptGet streams one apt transaction. update runs first on installs so a
// stale package index on a fresh server doesn't 404 the install.
func aptGet(ctx context.Context, emit Emit, verb string, packages []string) error {
	step := "install"
	if verb != "install" {
		step = "remove"
	}
	if verb == "install" {
		if err := rootStream(ctx, step, emit, "apt-get", "update"); err != nil {
			return fmt.Errorf("apt-get update: %w", err)
		}
	}
	args := []string{"-y"}
	if verb == "install" {
		args = append(args, "-o", "Dpkg::Options::=--force-confold", "install")
	} else {
		args = append(args, verb, "--autoremove")
	}
	args = append(args, packages...)
	if err := rootStream(ctx, step, emit, append([]string{"apt-get"}, args...)...); err != nil {
		return fmt.Errorf("apt-get %s: %w", verb, err)
	}
	return nil
}

// systemdRunArgv wraps argv in a transient unit: PID 1 spawns it outside the
// agent's ProtectSystem=strict mount namespace, --wait/--pipe give us the
// exit code and output as if we ran it directly.
func systemdRunArgv(argv []string) []string {
	return append([]string{
		"systemd-run", "--wait", "--collect", "--pipe", "--quiet",
		"--setenv=DEBIAN_FRONTEND=noninteractive", "--setenv=LC_ALL=C",
		"--description=deploypal recipe: " + strings.Join(argv, " "),
		"--",
	}, argv...)
}

// rootStream: a mutating command with live output relayed through emit.
func rootStream(ctx context.Context, step string, emit Emit, argv ...string) error {
	wrapped := systemdRunArgv(argv)
	return runStreaming(ctx, step, emit, wrapped[0], wrapped[1:]...)
}

// rootExec: a short mutating command; returns combined output.
func rootExec(ctx context.Context, argv ...string) (string, error) {
	wrapped := systemdRunArgv(argv)
	out, err := exec.CommandContext(ctx, wrapped[0], wrapped[1:]...).CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("%s: %s", strings.Join(argv, " "),
			strings.TrimSpace(string(out)))
	}
	return string(out), nil
}

// installFile stages content in the agent-writable RuntimeDirectory, then
// installs it to its read-only-to-us destination via the sandbox escape.
// mode is octal text ("0644"); owner is "user[:group]" ("" = root:root).
func installFile(ctx context.Context, content []byte, dst, mode, owner string) error {
	if err := os.MkdirAll(stagingDir, 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(stagingDir, "cfg-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(content); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	args := []string{"install", "-D", "-m", mode}
	if owner != "" {
		parts := strings.SplitN(owner, ":", 2)
		args = append(args, "-o", parts[0])
		if len(parts) == 2 {
			args = append(args, "-g", parts[1])
		}
	}
	args = append(args, tmp.Name(), dst)
	_, err = rootExec(ctx, args...)
	return err
}

// runStreaming executes argv (no shell), relaying combined output in ~line
// batches through emit while the step stays "running".
func runStreaming(ctx context.Context, step string, emit Emit, bin string, args ...string) error {
	cmd := exec.CommandContext(ctx, bin, args...)
	cmd.Env = append(os.Environ(), "DEBIAN_FRONTEND=noninteractive", "LC_ALL=C")
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	cmd.Stderr = cmd.Stdout // interleave, like a terminal
	emit(step, "running", "$ "+bin+" "+strings.Join(args, " "))
	if err := cmd.Start(); err != nil {
		return err
	}
	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 64*1024), 256*1024)
	var batch []string
	flush := func() {
		if len(batch) > 0 {
			emit(step, "running", strings.Join(batch, "\n"))
			batch = batch[:0]
		}
	}
	for scanner.Scan() {
		batch = append(batch, scanner.Text())
		if len(batch) >= 20 {
			flush()
		}
	}
	flush()
	if err := cmd.Wait(); err != nil {
		return fmt.Errorf("exited: %w", err)
	}
	return nil
}

// systemctl for units outside the deploypal-app namespace, restricted to the
// exact verbs the pipeline needs. (The D-Bus path in systemdctl guards its
// own allow-list; recipes carry their unit with them.)
func systemctl(ctx context.Context, verb, unit string) error {
	if verb != "restart" && verb != "stop" && verb != "enable" {
		return fmt.Errorf("verb %q not allowed", verb)
	}
	cmd := exec.CommandContext(ctx, "systemctl", verb, unit)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("systemctl %s %s: %s", verb, unit, strings.TrimSpace(string(out)))
	}
	return nil
}

// InstalledVersion returns the dpkg version of pkg, or "" when not installed.
func InstalledVersion(pkg string) string {
	out, err := exec.Command("dpkg-query", "-W", "-f=${db:Status-Status} ${Version}", pkg).Output()
	if err != nil {
		return ""
	}
	fields := strings.SplitN(strings.TrimSpace(string(out)), " ", 2)
	if len(fields) == 2 && fields[0] == "installed" {
		return fields[1]
	}
	return ""
}

// InstalledVersions batch-queries dpkg for many packages in one exec.
func InstalledVersions(pkgs []string) map[string]string {
	if len(pkgs) == 0 {
		return nil
	}
	args := append([]string{"-W", "-f=${Package} ${db:Status-Status} ${Version}\n"}, pkgs...)
	out, _ := exec.Command("dpkg-query", args...).Output() // unknown pkgs → error exit, known ones still print
	versions := map[string]string{}
	for _, line := range strings.Split(string(out), "\n") {
		fields := strings.SplitN(line, " ", 3)
		if len(fields) == 3 && fields[1] == "installed" {
			versions[fields[0]] = fields[2]
		}
	}
	return versions
}

// effectivePort: the port param when the recipe has one, else the fixed
// default_port (services whose port isn't configurable via the recipe).
func effectivePort(r *Recipe, params map[string]string) string {
	if p := params["port"]; p != "" {
		return p
	}
	if r.DefaultPort > 0 {
		return strconv.FormatUint(uint64(r.DefaultPort), 10)
	}
	return ""
}

func dialWithRetry(port string, timeout time.Duration) error {
	if port == "" {
		return nil
	}
	deadline := time.Now().Add(timeout)
	var last error
	for time.Now().Before(deadline) {
		conn, err := net.DialTimeout("tcp", "127.0.0.1:"+port, time.Second)
		if err == nil {
			conn.Close()
			return nil
		}
		last = err
		time.Sleep(time.Second)
	}
	return fmt.Errorf("service not accepting connections on 127.0.0.1:%s after %s (%v)", port, timeout, last)
}

func randomSecret(n int) (string, error) {
	raw := make([]byte, n)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(raw), nil
}
