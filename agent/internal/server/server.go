// server: the gRPC glue mapping deploypal.agent.v1.Agent RPCs onto the internal
// packages. Policy lives here in three forms only: path allow-lists for reads,
// name/format validation (delegated to nginxfs/systemdctl), and error shaping
// (expected operational failures → OpResult{ok:false}; programming/transport
// errors → gRPC status codes).
package server

import (
	"context"
	"fmt"
	"os"
	"os/user"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/fsnotify/fsnotify"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	agentv1 "github.com/deploypal/agent/gen/agentv1"
	"github.com/deploypal/agent/internal/journal"
	"github.com/deploypal/agent/internal/nginxfs"
	"github.com/deploypal/agent/internal/sysinfo"
	"github.com/deploypal/agent/internal/systemdctl"
)

// Read access is confined to the trees discovery legitimately needs, plus the
// /proc/<pid>/cwd symlinks the sweep resolves.
var (
	readRoots  = []string{"/etc/nginx/", "/srv/apps/", "/var/www/", "/opt/"}
	procCwdRx  = regexp.MustCompile(`^/proc/\d+/cwd$`)
	watchRoots = []string{"/etc/nginx/", "/etc/systemd/system/"}
)

type Server struct {
	agentv1.UnimplementedAgentServer

	scanMu  sync.Mutex // sysinfo.Scanner keeps state between scans
	scanner *sysinfo.Scanner

	sysdMu sync.Mutex
	sysd   *systemdctl.Conn
}

func New() *Server {
	return &Server{scanner: sysinfo.NewScanner()}
}

// systemd lazily opens (and caches) the D-Bus connection.
func (s *Server) systemd(ctx context.Context) (*systemdctl.Conn, error) {
	s.sysdMu.Lock()
	defer s.sysdMu.Unlock()
	if s.sysd == nil {
		c, err := systemdctl.Connect(ctx)
		if err != nil {
			return nil, status.Errorf(codes.Unavailable, "systemd dbus: %v", err)
		}
		s.sysd = c
	}
	return s.sysd, nil
}

func ok() *agentv1.OpResult { return &agentv1.OpResult{Ok: true} }
func fail(format string, a ...any) *agentv1.OpResult {
	return &agentv1.OpResult{Ok: false, Message: fmt.Sprintf(format, a...)}
}

// ---------------------------------------------------------------- discovery

func (s *Server) GetSystemInfo(ctx context.Context, _ *agentv1.Empty) (*agentv1.SystemInfo, error) {
	h := sysinfo.Host()
	return &agentv1.SystemInfo{
		Hostname: h.Hostname, Kernel: h.Kernel, Distro: h.Distro,
		MemTotal: h.MemTotal, CpuCount: h.CPUCount, Load1: h.Load1,
		DiskTotal: h.DiskTotal, DiskFree: h.DiskFree,
		AgentVersion: "0.1.0",
	}, nil
}

func (s *Server) ListProcesses(ctx context.Context, _ *agentv1.Empty) (*agentv1.ProcessList, error) {
	s.scanMu.Lock()
	procs, err := s.scanner.Scan()
	s.scanMu.Unlock()
	if err != nil {
		return nil, status.Errorf(codes.Internal, "proc scan: %v", err)
	}
	out := &agentv1.ProcessList{Processes: make([]*agentv1.ProcessInfo, 0, len(procs))}
	for _, p := range procs {
		out.Processes = append(out.Processes, &agentv1.ProcessInfo{
			Pid: p.PID, Ppid: p.PPID, Uid: p.UID, Comm: p.Comm,
			Cmdline: p.Cmdline, Cwd: p.Cwd, Exe: p.Exe, Unit: p.Unit,
			Rss: p.RSS, CpuPct: p.CPUPct,
		})
	}
	return out, nil
}

func (s *Server) ListListeningPorts(ctx context.Context, _ *agentv1.Empty) (*agentv1.PortList, error) {
	ports, err := sysinfo.ListListeningPorts()
	if err != nil {
		return nil, status.Errorf(codes.Internal, "port scan: %v", err)
	}
	out := &agentv1.PortList{Ports: make([]*agentv1.PortInfo, 0, len(ports))}
	for _, p := range ports {
		out.Ports = append(out.Ports, &agentv1.PortInfo{
			Port: uint32(p.Port), Proto: p.Proto, Address: p.Address,
			Pid: p.PID, Process: p.Comm, Unit: p.Unit,
		})
	}
	return out, nil
}

func (s *Server) ListNginxSites(ctx context.Context, _ *agentv1.Empty) (*agentv1.NginxSiteList, error) {
	sites, err := nginxfs.ListSites()
	if err != nil {
		return nil, status.Errorf(codes.Internal, "nginx scan: %v", err)
	}
	out := &agentv1.NginxSiteList{Sites: make([]*agentv1.NginxSite, 0, len(sites))}
	for _, site := range sites {
		out.Sites = append(out.Sites, &agentv1.NginxSite{
			Path: site.Path, Enabled: site.Enabled, Managed: site.Managed,
			Content: site.Content, Mtime: site.MTime,
		})
	}
	return out, nil
}

func (s *Server) ListUnits(ctx context.Context, req *agentv1.ListUnitsRequest) (*agentv1.UnitList, error) {
	sysd, err := s.systemd(ctx)
	if err != nil {
		return nil, err
	}
	pattern := req.Pattern
	if pattern == "" {
		pattern = "*.service"
	}
	units, err := sysd.ListUnits(ctx, pattern)
	if err != nil {
		return nil, status.Errorf(codes.Internal, "list units: %v", err)
	}
	out := &agentv1.UnitList{Units: make([]*agentv1.UnitInfo, 0, len(units))}
	for _, u := range units {
		out.Units = append(out.Units, &agentv1.UnitInfo{
			Name: u.Name, Description: u.Description, LoadState: u.LoadState,
			ActiveState: u.ActiveState, SubState: u.SubState,
			MainPid: u.MainPID, FragmentPath: u.FragmentPath, Enabled: u.Enabled,
		})
	}
	return out, nil
}

func readAllowed(path string) bool {
	clean := filepath.Clean(path)
	if procCwdRx.MatchString(clean) {
		return true
	}
	for _, root := range readRoots {
		if strings.HasPrefix(clean, root) {
			return true
		}
	}
	return false
}

func (s *Server) ReadFile(ctx context.Context, req *agentv1.ReadFileRequest) (*agentv1.FileContent, error) {
	if !readAllowed(req.Path) {
		return nil, status.Errorf(codes.PermissionDenied, "path %q outside readable roots", req.Path)
	}
	clean := filepath.Clean(req.Path)

	// /proc/<pid>/cwd and friends: return the symlink target, not the dir.
	if fi, err := os.Lstat(clean); err == nil && fi.Mode()&os.ModeSymlink != 0 {
		target, err := os.Readlink(clean)
		if err != nil {
			return nil, status.Errorf(codes.NotFound, "readlink: %v", err)
		}
		if procCwdRx.MatchString(clean) {
			return &agentv1.FileContent{Content: []byte(target)}, nil
		}
		clean = target // regular symlinked file: follow, then re-check the target
		if !readAllowed(clean) {
			return nil, status.Errorf(codes.PermissionDenied, "symlink target %q outside readable roots", clean)
		}
	}

	maxBytes := int64(req.MaxBytes)
	if maxBytes == 0 {
		maxBytes = 256 * 1024
	}
	f, err := os.Open(clean)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, status.Errorf(codes.NotFound, "%s", clean)
		}
		return nil, status.Errorf(codes.Internal, "open: %v", err)
	}
	defer f.Close()
	buf := make([]byte, maxBytes+1)
	n, _ := f.Read(buf)
	truncated := int64(n) > maxBytes
	if truncated {
		n = int(maxBytes)
	}
	return &agentv1.FileContent{Content: buf[:n], Truncated: truncated}, nil
}

func (s *Server) ListDir(ctx context.Context, req *agentv1.ListDirRequest) (*agentv1.DirListing, error) {
	if !readAllowed(req.Path) {
		return nil, status.Errorf(codes.PermissionDenied, "path %q outside readable roots", req.Path)
	}
	entries, err := os.ReadDir(filepath.Clean(req.Path))
	if err != nil {
		if os.IsNotExist(err) {
			return nil, status.Errorf(codes.NotFound, "%s", req.Path)
		}
		return nil, status.Errorf(codes.Internal, "readdir: %v", err)
	}
	out := &agentv1.DirListing{Entries: make([]*agentv1.DirEntry, 0, len(entries))}
	for _, e := range entries {
		de := &agentv1.DirEntry{Name: e.Name(), IsDir: e.IsDir()}
		if info, err := e.Info(); err == nil {
			de.Size = info.Size()
		}
		out.Entries = append(out.Entries, de)
	}
	return out, nil
}

// ---------------------------------------------------------------- ports

func (s *Server) FindFreePort(ctx context.Context, req *agentv1.FindFreePortRequest) (*agentv1.FindFreePortResponse, error) {
	start, end := uint16(req.RangeStart), uint16(req.RangeEnd)
	if start == 0 {
		start = 3000
	}
	if end == 0 {
		end = 3999
	}
	exclude := make(map[uint16]bool, len(req.Exclude))
	for _, p := range req.Exclude {
		exclude[uint16(p)] = true
	}
	port, err := sysinfo.FindFreePort(start, end, exclude)
	if err != nil {
		return nil, status.Errorf(codes.ResourceExhausted, "%v", err)
	}
	return &agentv1.FindFreePortResponse{Port: uint32(port)}, nil
}

// ---------------------------------------------------------------- provisioning

func (s *Server) InstallUnit(ctx context.Context, req *agentv1.InstallUnitRequest) (*agentv1.OpResult, error) {
	sysd, err := s.systemd(ctx)
	if err != nil {
		return nil, err
	}
	if err := sysd.InstallUnit(ctx, req.Name, req.Content, req.Enable, req.StartNow); err != nil {
		return fail("install %s: %v", req.Name, err), nil
	}
	return ok(), nil
}

func (s *Server) RemoveUnit(ctx context.Context, req *agentv1.UnitRef) (*agentv1.OpResult, error) {
	sysd, err := s.systemd(ctx)
	if err != nil {
		return nil, err
	}
	if err := sysd.RemoveUnit(ctx, req.Name); err != nil {
		return fail("remove %s: %v", req.Name, err), nil
	}
	return ok(), nil
}

func (s *Server) UnitAction(ctx context.Context, req *agentv1.UnitActionRequest) (*agentv1.OpResult, error) {
	sysd, err := s.systemd(ctx)
	if err != nil {
		return nil, err
	}
	if err := sysd.Action(ctx, req.Name, req.Action); err != nil {
		return fail("%s %s: %v", req.Action, req.Name, err), nil
	}
	return ok(), nil
}

func (s *Server) WriteNginxSite(ctx context.Context, req *agentv1.WriteNginxSiteRequest) (*agentv1.OpResult, error) {
	if err := nginxfs.WriteSite(req.Filename, req.Content); err != nil {
		return fail("write site: %v", err), nil
	}
	return ok(), nil
}

func (s *Server) EnableNginxSite(ctx context.Context, req *agentv1.NginxSiteRef) (*agentv1.OpResult, error) {
	if err := nginxfs.EnableSite(req.Filename); err != nil {
		return fail("enable site: %v", err), nil
	}
	return ok(), nil
}

func (s *Server) DisableNginxSite(ctx context.Context, req *agentv1.NginxSiteRef) (*agentv1.OpResult, error) {
	if err := nginxfs.DisableSite(req.Filename); err != nil {
		return fail("disable site: %v", err), nil
	}
	return ok(), nil
}

func (s *Server) TestNginxConfig(ctx context.Context, _ *agentv1.Empty) (*agentv1.OpResult, error) {
	if passed, out := nginxfs.TestConfig(); !passed {
		return fail("nginx -t failed:\n%s", out), nil
	}
	return ok(), nil
}

func (s *Server) ReloadNginx(ctx context.Context, _ *agentv1.Empty) (*agentv1.OpResult, error) {
	if passed, out := nginxfs.Reload(); !passed {
		return fail("nginx reload failed:\n%s", out), nil
	}
	return ok(), nil
}

func (s *Server) ObtainCertificate(ctx context.Context, req *agentv1.CertRequest) (*agentv1.OpResult, error) {
	if passed, out := nginxfs.ObtainCertificate(req.Domains, req.ContactEmail); !passed {
		return fail("certbot failed:\n%s", out), nil
	}
	return ok(), nil
}

// ---------------------------------------------------------------- streaming

func (s *Server) StreamLogs(req *agentv1.LogStreamRequest, stream agentv1.Agent_StreamLogsServer) error {
	ctx := stream.Context()
	lines := make(chan journal.Line, 256)
	errCh := make(chan error, 1)
	go func() {
		errCh <- journal.Stream(ctx, journal.StreamOpts{
			Unit: req.Unit, TailLines: req.TailLines,
			Follow: req.Follow, Cursor: req.Cursor,
		}, lines)
		close(lines)
	}()
	for line := range lines {
		if err := stream.Send(&agentv1.LogLine{
			TsMicros: line.TSMicros, Priority: line.Priority,
			Message: line.Message, Cursor: line.Cursor,
		}); err != nil {
			return err
		}
	}
	if err := <-errCh; err != nil && ctx.Err() == nil {
		return status.Errorf(codes.Internal, "journal stream: %v", err)
	}
	return nil
}

func (s *Server) StreamResources(req *agentv1.ResourceStreamRequest, stream agentv1.Agent_StreamResourcesServer) error {
	ctx := stream.Context()
	interval := time.Duration(req.IntervalSeconds) * time.Second
	if interval == 0 {
		interval = 5 * time.Second
	}

	// Resolve each unit's WorkingDirectory once; disk is re-walked only every
	// 12th tick (a full tree walk is much heavier than a cgroup read).
	workDirs := map[string]string{}
	if sysd, err := s.systemd(ctx); err == nil {
		for _, unit := range req.Units {
			workDirs[unit] = sysd.WorkingDirectory(ctx, unit)
		}
	}

	prev := map[string]sysinfo.CgroupSample{}
	disk := map[string]uint64{}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for tick := 0; ; tick++ {
		for _, unit := range req.Units {
			cur, err := sysinfo.ReadCgroup(unit)
			if err != nil {
				continue // unit not running right now
			}
			sample := &agentv1.ResourceSample{
				Unit: unit, Ts: time.Now().Unix(), MemBytes: cur.MemBytes,
			}
			if p, seen := prev[unit]; seen && cur.CPUUsec >= p.CPUUsec {
				sample.CpuPct = float64(cur.CPUUsec-p.CPUUsec) / interval.Seconds() / 1e6 * 100
			}
			prev[unit] = cur
			if tick%12 == 0 {
				if wd := workDirs[unit]; wd != "" {
					disk[unit] = sysinfo.DirSize(wd)
				}
			}
			sample.DiskBytes = disk[unit]
			if err := stream.Send(sample); err != nil {
				return err
			}
		}
		select {
		case <-ticker.C:
		case <-ctx.Done():
			return nil
		}
	}
}

func (s *Server) WatchPaths(req *agentv1.WatchPathsRequest, stream agentv1.Agent_WatchPathsServer) error {
	watcher, err := fsnotify.NewWatcher()
	if err != nil {
		return status.Errorf(codes.Internal, "fsnotify: %v", err)
	}
	defer watcher.Close()

	for _, p := range req.Paths {
		clean := filepath.Clean(p) + "/"
		allowed := false
		for _, root := range watchRoots {
			if strings.HasPrefix(clean, root) {
				allowed = true
				break
			}
		}
		if !allowed {
			return status.Errorf(codes.PermissionDenied, "path %q not watchable", p)
		}
		if err := watcher.Add(filepath.Clean(p)); err != nil {
			return status.Errorf(codes.NotFound, "watch %s: %v", p, err)
		}
	}

	ctx := stream.Context()
	for {
		select {
		case ev, open := <-watcher.Events:
			if !open {
				return nil
			}
			op := strings.ToLower(ev.Op.String()) // "create", "write|chmod", ...
			if err := stream.Send(&agentv1.FsEvent{
				Path: ev.Name, Op: op, Ts: time.Now().Unix(),
			}); err != nil {
				return err
			}
		case <-watcher.Errors:
			// transient inotify errors: keep the stream alive
		case <-ctx.Done():
			return nil
		}
	}
}

// ---------------------------------------------------------------- socket setup

// ChownSocketToGroup sets the socket's group to the given user's primary
// group, so 0660 grants exactly root + the orchestrator access.
func ChownSocketToGroup(path, username string) error {
	u, err := user.Lookup(username)
	if err != nil {
		return err
	}
	gid, err := strconv.Atoi(u.Gid)
	if err != nil {
		return err
	}
	return os.Chown(path, 0, gid)
}
