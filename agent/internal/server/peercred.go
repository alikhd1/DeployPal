// SO_PEERCRED-based transport credentials: every UDS connection's peer UID is
// checked against the allowed orchestrator UID before gRPC sees it.
package server

import (
	"context"
	"fmt"
	"net"
	"os/user"
	"strconv"

	"golang.org/x/sys/unix"
	"google.golang.org/grpc/credentials"
)

type peerCredCreds struct {
	allowedUID uint32
}

func NewPeerCredCreds(allowedUID uint32) credentials.TransportCredentials {
	return &peerCredCreds{allowedUID: allowedUID}
}

func (c *peerCredCreds) ServerHandshake(conn net.Conn) (net.Conn, credentials.AuthInfo, error) {
	uc, ok := conn.(*net.UnixConn)
	if !ok {
		return nil, nil, fmt.Errorf("not a unix socket connection")
	}
	raw, err := uc.SyscallConn()
	if err != nil {
		return nil, nil, err
	}
	var cred *unix.Ucred
	var credErr error
	if err := raw.Control(func(fd uintptr) {
		cred, credErr = unix.GetsockoptUcred(int(fd), unix.SOL_SOCKET, unix.SO_PEERCRED)
	}); err != nil {
		return nil, nil, err
	}
	if credErr != nil {
		return nil, nil, credErr
	}
	if cred.Uid != 0 && cred.Uid != c.allowedUID {
		conn.Close()
		return nil, nil, fmt.Errorf("peer uid %d not permitted", cred.Uid)
	}
	return conn, peerAuthInfo{uid: cred.Uid, pid: cred.Pid}, nil
}

func (c *peerCredCreds) ClientHandshake(ctx context.Context, _ string, conn net.Conn) (net.Conn, credentials.AuthInfo, error) {
	return conn, peerAuthInfo{}, nil
}
func (c *peerCredCreds) Info() credentials.ProtocolInfo {
	return credentials.ProtocolInfo{SecurityProtocol: "peercred"}
}
func (c *peerCredCreds) Clone() credentials.TransportCredentials { return c }
func (c *peerCredCreds) OverrideServerName(string) error         { return nil }

type peerAuthInfo struct {
	uid uint32
	pid int32
}

func (peerAuthInfo) AuthType() string { return "peercred" }

func LookupUID(username string) (uint32, error) {
	u, err := user.Lookup(username)
	if err != nil {
		return 0, err
	}
	uid, err := strconv.ParseUint(u.Uid, 10, 32)
	return uint32(uid), err
}
