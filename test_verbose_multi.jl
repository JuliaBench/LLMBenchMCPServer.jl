#!/usr/bin/env julia

# Test verbose mode with multi-instance LLMBenchMCPServer

using Sockets
using JSON
using Base.Threads

println("Testing verbose mode with multi-instance server...")

# Start the server with verbose and multi flags
server_cmd = `julia --project=. -m LLMBenchMCPServer LLMBenchSimple --socket --multi --verbose --direct`

println("Starting server with command: $server_cmd")
server_proc = run(pipeline(server_cmd, stdout=stdout, stderr=stderr), wait=false)

# Wait for server to start and create socket
sleep(3)

# Look for actual socket files
socket_files = filter(f -> startswith(f, "mcp_LLMBenchSimple"), readdir("/tmp"))
if !isempty(socket_files)
    # Sort by creation time and use the latest one
    sort!(socket_files, by=f->mtime(joinpath("/tmp", f)), rev=true)
    socket_path = joinpath("/tmp", socket_files[1])
    println("Found socket: $socket_path")
else
    println("ERROR: No socket file found!")
    kill(server_proc)
    exit(1)
end

# Test function to send a request
function send_request(socket, request)
    println(socket, JSON.json(request))
    flush(socket)
    response_line = readline(socket)
    return JSON.parse(response_line)
end

# Connect two clients simultaneously
println("\n=== Testing with two simultaneous connections ===\n")

try
    # Client 1
    println("Client 1: Connecting to $socket_path")
    client1 = connect(socket_path)

    # Client 2
    println("Client 2: Connecting to $socket_path")
    client2 = connect(socket_path)

    # Initialize both clients
    println("\nClient 1: Sending initialize request")
    init_request = Dict(
        "jsonrpc" => "2.0",
        "method" => "initialize",
        "params" => Dict(
            "protocolVersion" => "2024-11-05",
            "capabilities" => Dict(),
            "clientInfo" => Dict("name" => "test-client-1", "version" => "1.0")
        ),
        "id" => 1
    )
    response1 = send_request(client1, init_request)
    println("Client 1: Received response: ", response1["result"]["serverInfo"]["name"])

    println("\nClient 2: Sending initialize request")
    init_request["params"]["clientInfo"]["name"] = "test-client-2"
    init_request["id"] = 1
    response2 = send_request(client2, init_request)
    println("Client 2: Received response: ", response2["result"]["serverInfo"]["name"])

    # List tools from both clients
    println("\nClient 1: Listing tools")
    list_tools_request = Dict(
        "jsonrpc" => "2.0",
        "method" => "tools/list",
        "params" => Dict(),
        "id" => 2
    )
    tools1 = send_request(client1, list_tools_request)
    println("Client 1: Found $(length(tools1["result"]["tools"])) tools")

    println("\nClient 2: Listing tools")
    tools2 = send_request(client2, list_tools_request)
    println("Client 2: Found $(length(tools2["result"]["tools"])) tools")

    # Setup problem on both clients with different problem IDs
    println("\nClient 1: Setting up problem 'test_problem_1'")
    setup_request = Dict(
        "jsonrpc" => "2.0",
        "method" => "tools/call",
        "params" => Dict(
            "name" => "setup_problem",
            "arguments" => Dict("problem_id" => "test_problem_1")
        ),
        "id" => 3
    )
    setup1 = send_request(client1, setup_request)
    println("Client 1: Problem setup complete")

    println("\nClient 2: Setting up problem 'test_problem_2'")
    setup_request["params"]["arguments"]["problem_id"] = "test_problem_2"
    setup2 = send_request(client2, setup_request)
    println("Client 2: Problem setup complete")

    # Close connections
    println("\nClosing connections...")
    close(client1)
    close(client2)

    println("\n=== Test completed successfully ===")

catch e
    println("Error during test: $e")
    rethrow(e)
finally
    # Kill the server
    kill(server_proc)
    sleep(1)
end

println("\nVerbose mode test complete!")
println("You should see detailed logging output above including:")
println("- Connection establishment messages")
println("- Incoming request logs")
println("- Outgoing response logs")
println("- Connection closure messages")