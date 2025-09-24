using LLMBenchMCPServer
using ClaudeMCPTools
using JSON
using Sockets
using Test

# Create a temporary module with test benchmarks
module TestMultiModule
    using LLMBenchSimple

    @bench "test1" begin
        promptval"What is 2 + 2?" == 4
    end

    @bench "test2" begin
        promptval"What is 3 * 3?" == 9
    end
end

mktempdir() do test_workspace
    # Start the server in multi-instance mode
    socket_path = joinpath(test_workspace, "test_multi.sock")

    # Start server in background - using the module directly
    server_task = @async begin
        try
            # Create server directly
            setup_fn = (wd, pid="") -> Main.TestMultiModule.setup_problem(wd, pid)
            grade_fn = (wd, t, pid="") -> Main.TestMultiModule.grade(wd, t, pid)

            LLMBenchMCPServer.run_server_multi_instance(
                setup_fn, grade_fn, socket_path, test_workspace,
                verbose=true, use_revise=false,
                include_basic_tools=true)
        catch e
            @error "Server error" exception=e
        end
    end

    # Wait for server to start
    sleep(2)

    # Test with two connections
    @testset "Multi-instance connections" begin
        results = []

        # Create two parallel connections
        tasks = []
        for i in 1:2
            task = @async begin
                client = connect(socket_path)

                # Initialize connection
                init_msg = Dict(
                    "jsonrpc" => "2.0",
                    "id" => "init-$i",
                    "method" => "initialize",
                    "params" => Dict(
                        "protocolVersion" => "0.1.0",
                        "capabilities" => Dict(),
                        "clientInfo" => Dict(
                            "name" => "test-client-$i",
                            "version" => "1.0.0"
                        )
                    )
                )

                println(client, JSON.json(init_msg))
                response = JSON.parse(readline(client))

                # Setup problem
                setup_msg = Dict(
                    "jsonrpc" => "2.0",
                    "id" => "setup-$i",
                    "method" => "tools/call",
                    "params" => Dict(
                        "name" => "setup_problem",
                        "arguments" => Dict("problem_id" => "test$i")
                    )
                )

                println(client, JSON.json(setup_msg))
                response = JSON.parse(readline(client))

                # Grade problem
                answer = i == 1 ? 4 : 9
                grade_msg = Dict(
                    "jsonrpc" => "2.0",
                    "id" => "grade-$i",
                    "method" => "tools/call",
                    "params" => Dict(
                        "name" => "grade_problem",
                        "arguments" => Dict(
                            "transcript" => "<answer>$answer</answer>",
                            "problem_id" => "test$i"
                        )
                    )
                )

                println(client, JSON.json(grade_msg))
                response = JSON.parse(readline(client))

                close(client)

                return response
            end
            push!(tasks, task)
        end

        # Wait for both tasks to complete
        for (i, task) in enumerate(tasks)
            result = fetch(task)
            push!(results, result)
            @test haskey(result, "result")
            println("Connection $i result: ", result)
        end

        # Check that instance directories were created
        instance_dirs = filter(x -> startswith(x, "instance_"), readdir(test_workspace))
        @test length(instance_dirs) >= 2
        println("Instance directories created: $instance_dirs")
    end

    # Stop the server by closing the socket
    # Since the server doesn't have a built-in stop mechanism,
    # we'll just let it be interrupted when the test ends

    # Clean up
    if isfile(socket_path)
        rm(socket_path)
    end
end

println("Multi-instance test completed successfully!")