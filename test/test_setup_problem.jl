@testset "SetupProblemTool" begin
    # Import necessary functions
    using ClaudeMCPTools: tool_schema, execute
    
    @testset "Tool schema" begin
        # Create a simple setup function
        setup_fn = (workdir, problem_id="") -> "Test problem description"
        tool = LLMBenchMCPServer.SetupProblemTool(setup_fn)
        
        schema = tool_schema(tool)
        @test schema["name"] == "setup_problem"
        @test haskey(schema, "description")
        @test haskey(schema, "inputSchema")
        @test schema["inputSchema"]["type"] == "object"
    end
    
    @testset "Execute with string return" begin
        setup_fn = (workdir, problem_id="") -> "This is a test problem"
        tool = LLMBenchMCPServer.SetupProblemTool(setup_fn)
        
        result = execute(tool, Dict())
        @test haskey(result, "content")
        @test result["content"][1]["type"] == "text"
        @test result["content"][1]["text"] == "This is a test problem"
    end
    
    @testset "Execute with dict return" begin
        setup_fn = (workdir, problem_id="") -> Dict(
            "description" => "Complex problem",
            "difficulty" => "medium"
        )
        tool = LLMBenchMCPServer.SetupProblemTool(setup_fn)
        
        result = execute(tool, Dict())
        @test haskey(result, "content")
        @test occursin("Complex problem", result["content"][1]["text"])
    end
    
    @testset "Working directory access" begin
        mktempdir() do tmpdir
            # Create a test file in the working directory
            test_file = joinpath(tmpdir, "test.txt")
            write(test_file, "test content")
            
            setup_fn = function(workdir, problem_id="")
                # Read from the working directory
                content = read(joinpath(workdir, "test.txt"), String)
                return "Found: $content"
            end
            
            tool = LLMBenchMCPServer.SetupProblemTool(setup_fn, working_dir=tmpdir)
            result = execute(tool, Dict())
            
            @test occursin("Found: test content", result["content"][1]["text"])
        end
    end
    
    @testset "Error handling" begin
        setup_fn = (workdir, problem_id="") -> error("Setup failed!")
        tool = LLMBenchMCPServer.SetupProblemTool(setup_fn)
        
        result = execute(tool, Dict())
        @test haskey(result, "content")
        @test occursin("Failed to setup problem", result["content"][1]["text"])
        @test occursin("Setup failed!", result["content"][1]["text"])
    end
end