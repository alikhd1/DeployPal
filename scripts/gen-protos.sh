#!/usr/bin/env bash
# Regenerate Python + Go gRPC stubs from the proto contract.
# Requires: pip install grpcio-tools
#           go install google.golang.org/protobuf/cmd/protoc-gen-go@latest
#           go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
proto="$root/proto/smise/agent/v1/agent.proto"

mkdir -p "$root/orchestrator/gen"
python -m grpc_tools.protoc -I "$root/proto" \
    --python_out="$root/orchestrator/gen" \
    --grpc_python_out="$root/orchestrator/gen" \
    --pyi_out="$root/orchestrator/gen" \
    "$proto"

# grpc_tools bundles protoc, so it drives the Go plugins too — no separate
# protoc install needed. module= strips the module prefix so output lands
# at agent/gen/agentv1/.
python -m grpc_tools.protoc -I "$root/proto" \
    --go_out="$root/agent"      --go_opt=module=github.com/smise/agent \
    --go-grpc_out="$root/agent" --go-grpc_opt=module=github.com/smise/agent \
    "$proto"

echo "stubs regenerated: orchestrator/gen/ and agent/gen/agentv1/"
