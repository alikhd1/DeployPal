// smise-agent: the only privileged component of DeployPal.
// Serves the smise.agent.v1.Agent gRPC service on a Unix domain socket.
package main

import (
	"log"
	"net"
	"os"
	"path/filepath"

	"google.golang.org/grpc"

	agentv1 "github.com/smise/agent/gen/agentv1"
	"github.com/smise/agent/internal/server"
)

const (
	socketPath = "/run/smise-navi/agent.sock"
	// UID allowed to connect (the `smise` orchestrator user); resolved at startup.
	orchestratorUser = "smise"
)

func main() {
	if err := os.MkdirAll(filepath.Dir(socketPath), 0o750); err != nil {
		log.Fatalf("socket dir: %v", err)
	}
	_ = os.Remove(socketPath) // stale socket from a previous run

	lis, err := net.Listen("unix", socketPath)
	if err != nil {
		log.Fatalf("listen: %v", err)
	}
	// Belt: filesystem permissions. Suspenders: SO_PEERCRED check per connection.
	if err := os.Chmod(socketPath, 0o660); err != nil {
		log.Fatalf("chmod socket: %v", err)
	}
	if err := server.ChownSocketToGroup(socketPath, orchestratorUser); err != nil {
		log.Fatalf("chown socket: %v", err)
	}

	allowedUID, err := server.LookupUID(orchestratorUser)
	if err != nil {
		log.Fatalf("resolve user %q: %v", orchestratorUser, err)
	}

	grpcServer := grpc.NewServer(
		grpc.Creds(server.NewPeerCredCreds(allowedUID)), // rejects any other UID (root always allowed)
		grpc.MaxRecvMsgSize(1<<20),
	)
	agentv1.RegisterAgentServer(grpcServer, server.New())

	log.Printf("smise-agent listening on %s (allowed uid %d)", socketPath, allowedUID)
	if err := grpcServer.Serve(lis); err != nil {
		log.Fatalf("serve: %v", err)
	}
}
