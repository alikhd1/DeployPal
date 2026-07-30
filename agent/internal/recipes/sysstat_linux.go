//go:build linux

package recipes

import (
	"fmt"

	"golang.org/x/sys/unix"
)

// diskFreeBytes returns free space at path (0 = unknown, check skipped).
func diskFreeBytes(path string) uint64 {
	var st unix.Statfs_t
	if err := unix.Statfs(path, &st); err != nil {
		return 0
	}
	return st.Bavail * uint64(st.Bsize)
}

// statModeOwner reads a file's mode and numeric owner for faithful rewrites.
func statModeOwner(path string) (mode, owner string, err error) {
	var st unix.Stat_t
	if err := unix.Stat(path, &st); err != nil {
		return "", "", err
	}
	return fmt.Sprintf("%04o", st.Mode&0o7777),
		fmt.Sprintf("%d:%d", st.Uid, st.Gid), nil
}
