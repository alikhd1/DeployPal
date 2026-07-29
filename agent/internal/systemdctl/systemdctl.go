// systemd control over D-Bus (coreos/go-systemd/dbus) — no systemctl shelling.
// Unit names are constrained: the agent will only install/remove units matching
// the managed pattern, and will only start/stop/restart managed units plus an
// explicit allow-list of infrastructure services (databases the UI controls).
package systemdctl

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"time"

	sd "github.com/coreos/go-systemd/v22/dbus"
)

const unitDir = "/etc/systemd/system"

var (
	managedUnit = regexp.MustCompile(`^smise-app-[a-z0-9-]{2,40}\.service$`)
	// Infra services the dashboard may start/stop/restart (not install/remove).
	actionAllowList = map[string]bool{
		"postgresql.service": true, "mysql.service": true, "mariadb.service": true,
		"redis-server.service": true, "mongod.service": true, "rabbitmq-server.service": true,
		"nginx.service": true,
	}
)

type Conn struct{ dbus *sd.Conn }

func Connect(ctx context.Context) (*Conn, error) {
	c, err := sd.NewSystemConnectionContext(ctx)
	if err != nil {
		return nil, err
	}
	return &Conn{dbus: c}, nil
}

// InstallUnit writes the unit file, daemon-reloads, and optionally enables/starts.
func (c *Conn) InstallUnit(ctx context.Context, name, content string, enable, startNow bool) error {
	if !managedUnit.MatchString(name) {
		return fmt.Errorf("unit %q outside managed namespace", name)
	}
	path := filepath.Join(unitDir, name)
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(content), 0o644); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		return err
	}
	if err := c.dbus.ReloadContext(ctx); err != nil {
		return fmt.Errorf("daemon-reload: %w", err)
	}
	if enable {
		if _, _, err := c.dbus.EnableUnitFilesContext(ctx, []string{name}, false, true); err != nil {
			return fmt.Errorf("enable: %w", err)
		}
	}
	if startNow {
		return c.Action(ctx, name, "restart") // restart = idempotent start
	}
	return nil
}

func (c *Conn) RemoveUnit(ctx context.Context, name string) error {
	if !managedUnit.MatchString(name) {
		return fmt.Errorf("unit %q outside managed namespace", name)
	}
	_ = c.Action(ctx, name, "stop")
	_, _ = c.dbus.DisableUnitFilesContext(ctx, []string{name}, false)
	if err := os.Remove(filepath.Join(unitDir, name)); err != nil && !os.IsNotExist(err) {
		return err
	}
	return c.dbus.ReloadContext(ctx)
}

// Action runs start/stop/restart and waits for the systemd job to finish, so
// the caller gets a real result, not fire-and-forget.
func (c *Conn) Action(ctx context.Context, name, action string) error {
	if !managedUnit.MatchString(name) && !actionAllowList[name] {
		return fmt.Errorf("unit %q not controllable", name)
	}
	done := make(chan string, 1)
	var err error
	switch action {
	case "start":
		_, err = c.dbus.StartUnitContext(ctx, name, "replace", done)
	case "stop":
		_, err = c.dbus.StopUnitContext(ctx, name, "replace", done)
	case "restart":
		_, err = c.dbus.RestartUnitContext(ctx, name, "replace", done)
	default:
		return fmt.Errorf("unknown action %q", action)
	}
	if err != nil {
		return err
	}
	select {
	case result := <-done:
		if result != "done" {
			return fmt.Errorf("%s %s: job result %q", action, name, result)
		}
		return nil
	case <-time.After(30 * time.Second):
		return fmt.Errorf("%s %s: timed out waiting for systemd job", action, name)
	case <-ctx.Done():
		return ctx.Err()
	}
}

type UnitStatus struct {
	Name, Description, LoadState, ActiveState, SubState, FragmentPath string
	MainPID                                                           int32
	Enabled                                                           bool
}

func (c *Conn) ListUnits(ctx context.Context, pattern string) ([]UnitStatus, error) {
	units, err := c.dbus.ListUnitsByPatternsContext(ctx, nil, []string{pattern})
	if err != nil {
		return nil, err
	}
	out := make([]UnitStatus, 0, len(units))
	for _, u := range units {
		st := UnitStatus{
			Name: u.Name, Description: u.Description,
			LoadState: u.LoadState, ActiveState: u.ActiveState, SubState: u.SubState,
		}
		if props, err := c.dbus.GetUnitTypePropertiesContext(ctx, u.Name, "Service"); err == nil {
			if pid, ok := props["MainPID"].(uint32); ok {
				st.MainPID = int32(pid)
			}
		}
		if prop, err := c.dbus.GetUnitPropertyContext(ctx, u.Name, "UnitFileState"); err == nil {
			if state, ok := prop.Value.Value().(string); ok {
				st.Enabled = state == "enabled"
			}
		}
		if prop, err := c.dbus.GetUnitPropertyContext(ctx, u.Name, "FragmentPath"); err == nil {
			if path, ok := prop.Value.Value().(string); ok {
				st.FragmentPath = path
			}
		}
		out = append(out, st)
	}
	return out, nil
}

// WorkingDirectory returns the unit's Service WorkingDirectory ("" if unset).
// Used by the resource streamer to compute per-app disk usage.
func (c *Conn) WorkingDirectory(ctx context.Context, name string) string {
	props, err := c.dbus.GetUnitTypePropertiesContext(ctx, name, "Service")
	if err != nil {
		return ""
	}
	wd, _ := props["WorkingDirectory"].(string)
	return wd
}
