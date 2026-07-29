# Regenerate Python + Go gRPC stubs from the proto contract (Windows).
# Requires: pip install grpcio-tools
#           go install google.golang.org/protobuf/cmd/protoc-gen-go@latest
#           go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest
$ErrorActionPreference = "Stop"
$root  = Split-Path $PSScriptRoot -Parent
$proto = Join-Path $root "proto\deploypal\agent\v1\agent.proto"

# Go plugins live in %USERPROFILE%\go\bin unless GOBIN overrides; make sure
# protoc (inside grpc_tools) can find them.
$goBin = Join-Path $env:USERPROFILE "go\bin"
if (Test-Path $goBin) { $env:PATH = "$goBin;$env:PATH" }

New-Item -ItemType Directory -Force (Join-Path $root "orchestrator\gen") | Out-Null
python -m grpc_tools.protoc -I "$root\proto" `
    --python_out="$root\orchestrator\gen" `
    --grpc_python_out="$root\orchestrator\gen" `
    --pyi_out="$root\orchestrator\gen" `
    $proto
if ($LASTEXITCODE -ne 0) { throw "python stub generation failed" }

# grpc_tools bundles protoc, so it drives the Go plugins too. module= strips
# the module prefix so output lands at agent\gen\agentv1\.
python -m grpc_tools.protoc -I "$root\proto" `
    --go_out="$root\agent"      --go_opt=module=github.com/deploypal/agent `
    --go-grpc_out="$root\agent" --go-grpc_opt=module=github.com/deploypal/agent `
    $proto
if ($LASTEXITCODE -ne 0) { throw "go stub generation failed" }

Write-Host "stubs regenerated: orchestrator\gen\ and agent\gen\agentv1\"
