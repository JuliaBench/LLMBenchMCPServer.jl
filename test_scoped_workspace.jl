#!/usr/bin/env julia

# Test that workspace is properly scoped in multi-instance mode

using Sockets
using JSON

println("Testing workspace scoping in multi-instance mode...")

# First, create a test benchmark module that uses LLMBenchSimple
test_module_code = """
module TestBenchmark
using LLMBenchSimple

@bench "workspace_test" begin
    # Create a test file in the workspace
    workdir = llmbench_workdir()
    test_file = joinpath(workdir, "workspace_test.txt")
    write(test_file, "Workspace: \$workdir")

    promptval"What workspace directory am I using?"

    # Check if the file was created in the right place
    @test isfile(test_file)
    @test occursin(workdir, read(test_file, String))
end

end
"""

# Write the test module
mkpath("test_benchmarks")
write("test_benchmarks/TestBenchmark.jl", test_module_code)

# Load the module
include("test_benchmarks/TestBenchmark.jl")

# Start the MCP server with this module
server_cmd = `julia --project=. -m LLMBenchMCPServer TestBenchmark --socket --multi --verbose --direct`
println("Starting server: $server_cmd")

server_proc = run(pipeline(server_cmd, stdout=stdout, stderr=stderr), wait=false)

# Wait for server to start
sleep(3)

# Find the socket file
socket_files = filter(f -> startswith(f, "mcp_TestBenchmark"), readdir("/tmp"))
if isempty(socket_files)
    println("ERROR: No socket file found!")
    kill(server_proc)
    exit(1)
end

socket_path = joinpath("/tmp", socket_files[1])
println("Found socket: $socket_path")

# Helper function
function send_request(socket, request)
    println(socket, JSON.json(request))
    flush(socket)
    response_line = readline(socket)
    return JSON.parse(response_line)
end

# Test with two clients
println("\n=== Testing with two clients ===")

try
    # Connect two clients
    client1 = connect(socket_path)
    client2 = connect(socket_path)

    # Initialize both
    for (i, client) in enumerate([client1, client2])
        init_request = Dict(
            "jsonrpc" => "2.0",
            "method" => "initialize",
            "params" => Dict(
                "protocolVersion" => "2024-11-05",
                "capabilities" => Dict(),
                "clientInfo" => Dict("name" => "test-client-$i", "version" => "1.0")
            ),
            "id" => 1
        )
        response = send_request(client, init_request)
        println("Client $i initialized: ", response["result"]["serverInfo"]["name"])
    end

    # Setup problem on both clients
    println("\nSetting up problems...")
    for (i, client) in enumerate([client1, client2])
        setup_request = Dict(
            "jsonrpc" => "2.0",
            "method" => "tools/call",
            "params" => Dict(
                "name" => "setup_problem",
                "arguments" => Dict("problem_id" => "workspace_test")
            ),
            "id" => 2
        )
        response = send_request(client, setup_request)

        if haskey(response, "result")
            text = response["result"]["content"][1]["text"]
            println("Client $i problem setup response includes workspace info")

            # The response should mention the workspace directory
            if occursin("/instance_", text)
                println("  ✓ Client $i has unique workspace in response")
            else
                println("  ✗ Client $i missing workspace info in response")
            end
        else
            println("  ✗ Client $i setup failed: ", get(response, "error", "unknown error"))
        end
    end

    # Check that files were created in different directories
    println("\nChecking workspace isolation...")
    instances = filter(d -> startswith(d, "instance_"), readdir(pwd()))
    println("Found $(length(instances)) instance directories")

    for dir in instances
        test_file = joinpath(pwd(), dir, "workspace_test.txt")
        if isfile(test_file)
            content = read(test_file, String)
            println("  Instance $dir: file exists with content: '$content'")
        else
            println("  Instance $dir: no test file found")
        end
    end

    close(client1)
    close(client2)

catch e
    println("Error: $e")
finally
    # Clean up
    kill(server_proc)
    sleep(1)

    # Clean up test files
    rm("test_benchmarks", recursive=true, force=true)
    for dir in filter(d -> startswith(d, "instance_"), readdir(pwd()))
        rm(dir, recursive=true, force=true)
    end
end

println("\nTest completed!")