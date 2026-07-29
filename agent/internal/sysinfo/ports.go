// Listening-port discovery and free-port allocation.
//
// Strategy: parse /proc/net/tcp and /proc/net/tcp6 for sockets in LISTEN state
// (st == 0A), collect their inodes, then invert /proc/<pid>/fd/* symlinks
// ("socket:[inode]") to map each socket back to its owning process. This is
// exactly what `ss -tlnp` does, without shelling out.
package sysinfo

import (
	"bufio"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

type ListeningPort struct {
	Port    uint16
	Proto   string // tcp | tcp6
	Address string
	PID     int32  // -1 if unresolved (e.g. kernel socket)
	Comm    string
	Unit    string // owning systemd unit from /proc/<pid>/cgroup
}

const stateListen = "0A"

// ListListeningPorts scans the socket tables once and resolves owners.
func ListListeningPorts() ([]ListeningPort, error) {
	inodeToSock := map[uint64]*ListeningPort{}
	for _, table := range []string{"/proc/net/tcp", "/proc/net/tcp6"} {
		if err := parseSocketTable(table, inodeToSock); err != nil {
			return nil, err
		}
	}
	resolveOwners(inodeToSock)

	out := make([]ListeningPort, 0, len(inodeToSock))
	for _, p := range inodeToSock {
		out = append(out, *p)
	}
	return out, nil
}

func parseSocketTable(path string, into map[uint64]*ListeningPort) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()

	proto := "tcp"
	if strings.HasSuffix(path, "6") {
		proto = "tcp6"
	}
	sc := bufio.NewScanner(f)
	sc.Scan() // header
	for sc.Scan() {
		// sl local_address rem_address st ... inode
		fields := strings.Fields(sc.Text())
		if len(fields) < 10 || fields[3] != stateListen {
			continue
		}
		addr, port, err := parseHexAddr(fields[1])
		if err != nil {
			continue
		}
		inode, err := strconv.ParseUint(fields[9], 10, 64)
		if err != nil || inode == 0 {
			continue
		}
		into[inode] = &ListeningPort{Port: port, Proto: proto, Address: addr, PID: -1}
	}
	return sc.Err()
}

// parseHexAddr decodes "0100007F:0BB8" → ("127.0.0.1", 3000).
func parseHexAddr(s string) (string, uint16, error) {
	host, portHex, ok := strings.Cut(s, ":")
	if !ok {
		return "", 0, fmt.Errorf("bad addr %q", s)
	}
	port64, err := strconv.ParseUint(portHex, 16, 16)
	if err != nil {
		return "", 0, err
	}
	raw, err := decodeHexIP(host) // little-endian per 32-bit group
	if err != nil {
		return "", 0, err
	}
	return raw.String(), uint16(port64), nil
}

// resolveOwners walks /proc/<pid>/fd once, matching socket inodes.
func resolveOwners(inodes map[uint64]*ListeningPort) {
	procs, _ := os.ReadDir("/proc")
	for _, e := range procs {
		pid, err := strconv.ParseInt(e.Name(), 10, 32)
		if err != nil {
			continue
		}
		fds, err := os.ReadDir(filepath.Join("/proc", e.Name(), "fd"))
		if err != nil {
			continue // process exited, or (shouldn't happen as root) unreadable
		}
		for _, fd := range fds {
			link, err := os.Readlink(filepath.Join("/proc", e.Name(), "fd", fd.Name()))
			if err != nil || !strings.HasPrefix(link, "socket:[") {
				continue
			}
			inode, err := strconv.ParseUint(link[8:len(link)-1], 10, 64)
			if err != nil {
				continue
			}
			if lp, ok := inodes[inode]; ok && lp.PID == -1 {
				lp.PID = int32(pid)
				lp.Comm = readProcString(int32(pid), "comm")
				lp.Unit = unitFromCgroup(int32(pid))
			}
		}
	}
}

// FindFreePort returns the first port in [start,end] that is neither in the
// live socket table, nor in the orchestrator's DB reservations (exclude), and
// that we can actually bind — closing the TOCTOU window as far as possible.
func FindFreePort(start, end uint16, exclude map[uint16]bool) (uint16, error) {
	listening, err := ListListeningPorts()
	if err != nil {
		return 0, err
	}
	busy := make(map[uint16]bool, len(listening))
	for _, p := range listening {
		busy[p.Port] = true
	}
	for port := start; port <= end; port++ {
		if busy[port] || exclude[port] {
			continue
		}
		l, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
		if err != nil {
			continue // squatter appeared between scan and probe
		}
		l.Close()
		return port, nil
	}
	return 0, fmt.Errorf("no free port in range %d-%d", start, end)
}
