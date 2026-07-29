// Process scanning via /proc — no external deps, one pass, CPU% computed as a
// delta against the previous scan (the scanner is a long-lived struct).
package sysinfo

import (
	"bytes"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"
	"syscall"
	"time"
)

type Process struct {
	PID     int32
	PPID    int32
	UID     uint32
	Comm    string
	Cmdline string
	Cwd     string
	Exe     string
	Unit    string
	RSS     uint64
	CPUPct  float64
}

// Scanner keeps per-PID jiffy counters between scans so CPUPct is meaningful.
type Scanner struct {
	prevJiffies map[int32]uint64
	prevTime    time.Time
	clockTick   float64 // sysconf(_SC_CLK_TCK), almost always 100
	pageSize    uint64
}

func NewScanner() *Scanner {
	return &Scanner{
		prevJiffies: map[int32]uint64{},
		clockTick:   100,
		pageSize:    uint64(os.Getpagesize()),
	}
}

func (s *Scanner) Scan() ([]Process, error) {
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return nil, err
	}
	now := time.Now()
	elapsed := now.Sub(s.prevTime).Seconds()
	next := map[int32]uint64{}
	var out []Process

	for _, e := range entries {
		pid64, err := strconv.ParseInt(e.Name(), 10, 32)
		if err != nil {
			continue
		}
		pid := int32(pid64)
		p, jiffies, ok := s.readOne(pid)
		if !ok {
			continue // raced with exit
		}
		next[pid] = jiffies
		if prev, seen := s.prevJiffies[pid]; seen && elapsed > 0 && jiffies >= prev {
			p.CPUPct = float64(jiffies-prev) / s.clockTick / elapsed * 100
		}
		out = append(out, p)
	}
	s.prevJiffies, s.prevTime = next, now
	return out, nil
}

func (s *Scanner) readOne(pid int32) (Process, uint64, bool) {
	statB, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
	if err != nil {
		return Process{}, 0, false
	}
	// comm may contain spaces/parens — split around the last ')'.
	closeParen := bytes.LastIndexByte(statB, ')')
	if closeParen < 0 {
		return Process{}, 0, false
	}
	fields := strings.Fields(string(statB[closeParen+2:]))
	if len(fields) < 22 {
		return Process{}, 0, false
	}
	ppid, _ := strconv.ParseInt(fields[1], 10, 32)  // stat field 4
	utime, _ := strconv.ParseUint(fields[11], 10, 64) // stat field 14
	stime, _ := strconv.ParseUint(fields[12], 10, 64) // stat field 15
	rssPages, _ := strconv.ParseUint(fields[21], 10, 64) // stat field 24

	p := Process{
		PID:     pid,
		PPID:    int32(ppid),
		Comm:    readProcString(pid, "comm"),
		Cmdline: readCmdline(pid),
		Unit:    unitFromCgroup(pid),
		RSS:     rssPages * s.pageSize,
	}
	p.Cwd, _ = os.Readlink(fmt.Sprintf("/proc/%d/cwd", pid))
	p.Exe, _ = os.Readlink(fmt.Sprintf("/proc/%d/exe", pid))
	if st, err := os.Stat(fmt.Sprintf("/proc/%d", pid)); err == nil {
		if sys, ok := st.Sys().(*syscall.Stat_t); ok {
			p.UID = sys.Uid
		}
	}
	return p, utime + stime, true
}

// --- helpers shared with ports.go ---

func readProcString(pid int32, name string) string {
	b, err := os.ReadFile(fmt.Sprintf("/proc/%d/%s", pid, name))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

func readCmdline(pid int32) string {
	b, err := os.ReadFile(fmt.Sprintf("/proc/%d/cmdline", pid))
	if err != nil {
		return ""
	}
	return strings.TrimRight(strings.ReplaceAll(string(b), "\x00", " "), " ")
}

// unitFromCgroup extracts "myapp.service" from
// "0::/system.slice/myapp.service" in /proc/<pid>/cgroup (cgroup v2).
func unitFromCgroup(pid int32) string {
	b, err := os.ReadFile(fmt.Sprintf("/proc/%d/cgroup", pid))
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(b), "\n") {
		if i := strings.LastIndexByte(line, '/'); i >= 0 {
			leaf := line[i+1:]
			if strings.HasSuffix(leaf, ".service") || strings.HasSuffix(leaf, ".scope") {
				return leaf
			}
		}
	}
	return ""
}

// decodeHexIP decodes the kernel's hex socket-address format (used by ports.go).
// IPv4: 8 hex chars, little-endian. IPv6: 32 hex chars in 4 LE 32-bit groups.
func decodeHexIP(h string) (net.IP, error) {
	raw, err := hex.DecodeString(h)
	if err != nil {
		return nil, err
	}
	switch len(raw) {
	case 4:
		return net.IPv4(raw[3], raw[2], raw[1], raw[0]), nil
	case 16:
		ip := make(net.IP, 16)
		for g := 0; g < 4; g++ {
			binary.BigEndian.PutUint32(ip[g*4:], binary.LittleEndian.Uint32(raw[g*4:]))
		}
		return ip, nil
	default:
		return nil, fmt.Errorf("unexpected address length %d", len(raw))
	}
}
