@testset "GradeProblemTool" begin
    # Import necessary functions
    using ClaudeMCPTools: tool_schema, execute
    
    @testset "Tool schema" begin
        grade_fn = (workdir, transcript, problem_id="") -> 1.0
        tool = LLMBenchMCPServer.GradeProblemTool(grade_fn)
        
        schema = tool_schema(tool)
        @test schema["name"] == "grade_problem"
        @test haskey(schema, "description")
        @test haskey(schema, "inputSchema")
        @test "transcript" in schema["inputSchema"]["required"]
    end
    
    @testset "Execute with dict return" begin
        grade_fn = (workdir, transcript, problem_id="") -> Dict(
            "subscores" => Dict("task1" => 0.8, "task2" => 0.9),
            "weights" => Dict("task1" => 0.5, "task2" => 0.5),
            "score" => 0.85
        )
        tool = LLMBenchMCPServer.GradeProblemTool(grade_fn)
        
        result = execute(tool, Dict("transcript" => "Test transcript"))
        @test haskey(result, "content")
        
        # Parse the JSON response
        grade_result = JSON.parse(result["content"][1]["text"])
        @test grade_result["score"] == 0.85
        @test grade_result["subscores"]["task1"] == 0.8
        @test grade_result["subscores"]["task2"] == 0.9
    end
    
    @testset "Execute with numeric return" begin
        grade_fn = (workdir, transcript, problem_id="") -> 0.75
        tool = LLMBenchMCPServer.GradeProblemTool(grade_fn)
        
        result = execute(tool, Dict("transcript" => "Test transcript"))
        @test haskey(result, "content")
        
        grade_result = JSON.parse(result["content"][1]["text"])
        @test grade_result["score"] == 0.75
        @test grade_result["subscores"]["total"] == 0.75
    end
    
    @testset "Auto-calculate score" begin
        grade_fn = (workdir, transcript, problem_id="") -> Dict(
            "subscores" => Dict("task1" => 0.6, "task2" => 0.8),
            "weights" => Dict("task1" => 0.3, "task2" => 0.7)
            # No score provided - should be calculated
        )
        tool = LLMBenchMCPServer.GradeProblemTool(grade_fn)
        
        result = execute(tool, Dict("transcript" => "Test transcript"))
        grade_result = JSON.parse(result["content"][1]["text"])
        
        # Should calculate: 0.6 * 0.3 + 0.8 * 0.7 = 0.18 + 0.56 = 0.74
        @test grade_result["score"] ≈ 0.74
    end
    
    @testset "Transcript access" begin
        mktempdir() do tmpdir
            grade_fn = function(workdir, transcript, problem_id="")
                # Check transcript content
                if occursin("correct answer", transcript)
                    return 1.0
                else
                    return 0.0
                end
            end
            
            tool = LLMBenchMCPServer.GradeProblemTool(grade_fn, working_dir=tmpdir)
            
            # Test with correct transcript
            result = execute(tool, Dict("transcript" => "The correct answer is 42"))
            grade_result = JSON.parse(result["content"][1]["text"])
            @test grade_result["score"] == 1.0
            
            # Test with incorrect transcript
            result = execute(tool, Dict("transcript" => "Wrong solution"))
            grade_result = JSON.parse(result["content"][1]["text"])
            @test grade_result["score"] == 0.0
        end
    end
    
    @testset "Error handling" begin
        grade_fn = (workdir, transcript, problem_id="") -> error("Grading failed!")
        tool = LLMBenchMCPServer.GradeProblemTool(grade_fn)
        
        result = execute(tool, Dict("transcript" => "Test"))
        grade_result = JSON.parse(result["content"][1]["text"])
        
        @test grade_result["score"] == 0.0
        @test haskey(grade_result, "error")
        @test occursin("Grading failed!", grade_result["error"])
    end
end