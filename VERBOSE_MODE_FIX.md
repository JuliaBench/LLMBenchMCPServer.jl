# Verbose Mode Fix for Multi-Instance Mode

## Summary

Fixed verbose mode in LLMBenchMCPServer to properly display request/response messages when running in multi-instance mode with the `--multi` and `--verbose` flags.

## Changes Made

### 1. Added Logging to `handle_client_connection` Function

In `/workspace/LLMBenchMCPServer/src/server.jl`:

- Added connection establishment logging when a new client connects
- Added request logging when receiving JSON-RPC requests
- Added response logging when sending responses back
- Added notification logging for JSON-RPC notifications
- Added connection closure logging when clients disconnect

### 2. Fixed Function Signature

- Updated `run_server_multi_instance` to accept `Union{Function, Nothing}` for setup and grade functions
- This allows the server to run even when the module doesn't provide these functions

## Verbose Mode Output

When running with `--verbose --multi` flags, you now see:

```julia
[ Info: MCP server (multi-instance) listening on Unix socket: /tmp/mcp_...
[ Info: New connection #1, working directory: /workspace/.../instance_...
[ Info: Connection established: Connection #1, directory: /workspace/...
┌ Info: Received request
│   connection = "Connection #1, directory: ..."
│   request = Dict{String, Any} with 4 entries:
│      "method"  => "initialize"
│      ...
┌ Info: Sending response
│   connection = "Connection #1, directory: ..."
│   response = Dict{String, Any} with 3 entries:
│      "result"  => Dict{String, Any}(...)
│      ...
[ Info: Connection closed: Connection #1, directory: ...
```

## Usage

Run the server with verbose output in multi-instance mode:

```bash
julia --project -m LLMBenchMCPServer ModuleName --socket --multi --verbose --direct
```

This provides full visibility into:
- Each client connection with unique working directory
- All JSON-RPC messages exchanged
- Connection lifecycle events

## Testing

Created test script `test_verbose_multi.jl` that:
1. Starts server with `--verbose --multi` flags
2. Connects multiple clients simultaneously
3. Sends requests from each client
4. Verifies verbose output is displayed

The verbose mode is essential for debugging multi-instance deployments where each client gets its own isolated working directory.