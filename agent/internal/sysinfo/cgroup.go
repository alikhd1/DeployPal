// Per-unit resource sampling from cgroup v2 (system.slice/<unit>/).
// CPU% is computed by the caller from usage deltas between samples.
package sysinfo

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

type CgroupSample struct {
	CPUUsec  uint64 // cumulative usage_usec from cpu.stat
	MemBytes uint64 // memory.current
}

func ReadCgroup(unit string) (CgroupSample, error) {
	base := filepath.Join("/sys/fs/cgroup/system.slice", unit)
	var s CgroupSample

	b, err := os.ReadFile(filepath.Join(base, "cpu.stat"))
	if err != nil {
		return s, fmt.Errorf("unit cgroup not found: %w", err)
	}
	for _, line := range strings.Split(string(b), "\n") {
		if v, ok := strings.CutPrefix(line, "usage_usec "); ok {
			s.CPUUsec, _ = strconv.ParseUint(strings.TrimSpace(v), 10, 64)
			break
		}
	}
	if b, err := os.ReadFile(filepath.Join(base, "memory.current")); err == nil {
		s.MemBytes, _ = strconv.ParseUint(strings.TrimSpace(string(b)), 10, 64)
	}
	return s, nil
}

// DirSize walks a tree summing file sizes — used for per-app disk usage,
// sampled far less often than CPU/memory (it's a full walk).
func DirSize(root string) uint64 {
	var total uint64
	_ = filepath.WalkDir(root, func(_ string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil // skip unreadable entries, keep walking
		}
		if info, err := d.Info(); err == nil {
			total += uint64(info.Size())
		}
		return nil
	})
	return total
}
