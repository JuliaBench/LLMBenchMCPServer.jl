#!/usr/bin/env julia

# Simple test of multi-instance mode
using LLMBenchMCPServer
using ClaudeMCPTools
using JSON
using Sockets

# Create a test module
module SimpleMultiTest
    using LLMBenchSimple

    @bench "add" begin
        promptval"What is 1 + 1?" == 2
    end
end

# Test configuration
test_workspace = mktempdir()
socket_path = joinpath(test_workspace, "multi_test.sock")

println("Starting server in multi-instance mode...")
println("Workspace: $test_workspace")
println("Socket: $socket_path")

# Start server in background
server_pid = @async begin
    try
        setup_fn = (wd, pid="") -> Main.SimpleMultiTest.setup_problem(wd, pid)
        grade_fn = (wd, t, pid="") -> Main.SimpleMultiTest.grade(wd, t, pid)

        # Start server with timeout
        timeout = Timer(15) do _
            println("\nServer running for 15 seconds, shutting down...")
        end

        LLMBenchMCPServer.run_server_multi_instance(
            setup_fn, grade_fn, socket_path, test_workspace,
            verbose=true, use_revise=false,
            include_basic_tools=false)
    catch e
        if !(e isa InterruptException)
            @error "Server error" exception=e
        end
    end
end

# Wait for server to start
sleep(2)

# Test two simultaneous connections
println("\nTesting two simultaneous connections...")

for i in 1:2
    @async begin
        try
            client = connect(socket_path)

            # Send initialization
            init_msg = Dict(
                "jsonrpc" => "2.0",
                "id" => 1,
                "method" => "initialize",
                "params" => Dict(
                    "protocolVersion" => "0.1.0",
                    "capabilities" => Dict()
                )
            )
            println(client, JSON.json(init_msg))
            response = JSON.parse(readline(client))
            println("Client $i initialized")

            # Setup problem
            setup_msg = Dict(
                "jsonrpc" => "2.0",
                "id" => 2,
                "method" => "tools/call",
                "params" => Dict(
                    "name" => "setup_problem",
                    "arguments" => Dict("problem_id" => "add")
                )
            )
            println(client, JSON.json(setup_msg))
            response = JSON.parse(readline(client))
            println("Client $i got problem: ", response["result"]["content"][1]["text"][1:50], "...")

            close(client)
        catch e
            @error "Client $i error" exception=e
        end
    end
end

# Wait a bit for connections to complete
sleep(3)

# Check created directories
instance_dirs = filter(x -> startswith(x, "instance_"), readdir(test_workspace))
println("\nInstance directories created: ", instance_dirs)
println("Number of instances: ", length(instance_dirs))

# Interrupt server after demonstration
Base.throwto(server_pid, InterruptException())
sleep(1)

# Cleanup
rm(test_workspace, recursive=true)
println("\nTest completed successfully!")