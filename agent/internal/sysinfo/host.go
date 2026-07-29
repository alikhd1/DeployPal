// Host-level facts for GetSystemInfo — all from /proc and statfs.
package sysinfo

import (
	"os"
	"runtime"
	"strconv"
	"strings"

	"golang.org/x/sys/unix"
)

type HostInfo struct {
	Hostname  string
	Kernel    string
	Distro    string
	MemTotal  uint64
	CPUCount  uint32
	Load1     float64
	DiskTotal uint64
	DiskFree  uint64
}

func Host() HostInfo {
	h := HostInfo{CPUCount: uint32(runtime.NumCPU())}
	h.Hostname, _ = os.Hostname()

	if b, err := os.ReadFile("/proc/sys/kernel/osrelease"); err == nil {
		h.Kernel = strings.TrimSpace(string(b))
	}
	if b, err := os.ReadFile("/etc/os-release"); err == nil {
		for _, line := range strings.Split(string(b), "\n") {
			if v, ok := strings.CutPrefix(line, "PRETTY_NAME="); ok {
				h.Distro = strings.Trim(v, `"`)
				break
			}
		}
	}
	if b, err := os.ReadFile("/proc/meminfo"); err == nil {
		for _, line := range strings.Split(string(b), "\n") {
			if v, ok := strings.CutPrefix(line, "MemTotal:"); ok {
				fields := strings.Fields(v) // "16303448 kB"
				if len(fields) > 0 {
					kb, _ := strconv.ParseUint(fields[0], 10, 64)
					h.MemTotal = kb * 1024
				}
				break
			}
		}
	}
	if b, err := os.ReadFile("/proc/loadavg"); err == nil {
		if fields := strings.Fields(string(b)); len(fields) > 0 {
			h.Load1, _ = strconv.ParseFloat(fields[0], 64)
		}
	}
	var st unix.Statfs_t
	if err := unix.Statfs("/", &st); err == nil {
		bs := uint64(st.Bsize)
		h.DiskTotal = st.Blocks * bs
		h.DiskFree = st.Bavail * bs
	}
	return h
}
