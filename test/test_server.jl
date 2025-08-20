@testset "LLMBenchServer" begin
    @testset "Server creation" begin
        server = LLMBenchMCPServer.LLMBenchServer(
            name="TestBench",
            version="1.0.0"
        )
        
        @test server.metadata["name"] == "TestBench"
        @test server.metadata["version"] == "1.0.0"
        
        # Should have basic tools by default
        @test haskey(server.tools, "bash")
        @test haskey(server.tools, "str_replace_editor")
    end
    
    @testset "Server with custom functions" begin
        setup_fn = (workdir) -> "Test problem"
        grade_fn = (workdir, transcript) -> 0.5
        
        server = LLMBenchMCPServer.LLMBenchServer(
            setup_fn=setup_fn,
            grade_fn=grade_fn
        )
        
        # Should have all tools
        @test haskey(server.tools, "bash")
        @test haskey(server.tools, "str_replace_editor")
        @test haskey(server.tools, "setup_problem")
        @test haskey(server.tools, "grade_problem")
    end
    
    @testset "Server without basic tools" begin
        server = LLMBenchMCPServer.LLMBenchServer(
            include_basic_tools=false
        )
        
        # Should not have basic tools
        @test !haskey(server.tools, "bash")
        @test !haskey(server.tools, "str_replace_editor")
    end
    
    @testset "Server integration test" begin
        setup_fn = (workdir) -> "Solve 2 + 2"
        grade_fn = function(workdir, transcript)
            if occursin("4", transcript)
                return Dict("score" => 1.0)
            else
                return Dict("score" => 0.0)
            end
        end
        
        server = LLMBenchMCPServer.LLMBenchServer(
            setup_fn=setup_fn,
            grade_fn=grade_fn
        )
        
        # Test setup_problem tool
        request = Dict(
            "jsonrpc" => "2.0",
            "id" => 1,
            "method" => "tools/call",
            "params" => Dict(
                "name" => "setup_problem",
                "arguments" => Dict()
            )
        )
        
        response = ClaudeMCPTools.handle_request(server, request)
        @test response["id"] == 1
        @test haskey(response, "result")
        @test occursin("Solve 2 + 2", response["result"]["content"][1]["text"])
        
        # Test grade_problem tool
        request = Dict(
            "jsonrpc" => "2.0",
            "id" => 2,
            "method" => "tools/call",
            "params" => Dict(
                "name" => "grade_problem",
                "arguments" => Dict("transcript" => "The answer is 4")
            )
        )
        
        response = ClaudeMCPTools.handle_request(server, request)
        @test response["id"] == 2
        @test haskey(response, "result")
        
        grade_result = JSON.parse(response["result"]["content"][1]["text"])
        @test grade_result["score"] == 1.0
    end
    
    @testset "Working directory handling" begin
        mktempdir() do tmpdir
            # Create test file
            test_file = joinpath(tmpdir, "data.txt")
            write(test_file, "42")
            
            setup_fn = function(workdir)
                data = read(joinpath(workdir, "data.txt"), String)
                return "Find the value: $data"
            end
            
            grade_fn = function(workdir, transcript)
                expected = read(joinpath(workdir, "data.txt"), String)
                if occursin(expected, transcript)
                    return 1.0
                else
                    return 0.0
                end
            end
            
            server = LLMBenchMCPServer.LLMBenchServer(
                setup_fn=setup_fn,
                grade_fn=grade_fn,
                working_dir=tmpdir
            )
            
            # Test that working directory is used
            request = Dict(
                "jsonrpc" => "2.0",
                "id" => 1,
                "method" => "tools/call",
                "params" => Dict(
                    "name" => "setup_problem",
                    "arguments" => Dict()
                )
            )
            
            response = ClaudeMCPTools.handle_request(server, request)
            @test occursin("Find the value: 42", response["result"]["content"][1]["text"])
        end
    end
end