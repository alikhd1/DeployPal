//go:build !linux

// Stubs so the package builds and its catalog tests run on dev machines;
// the agent itself only ever runs on Linux.
package recipes

import "fmt"

func diskFreeBytes(string) uint64 { return 0 }

func statModeOwner(string) (string, string, error) {
	return "", "", fmt.Errorf("statModeOwner: linux only")
}
